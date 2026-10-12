//
//  SafariWebExtensionHandler.swift
//  InspirationLibrary Extension
//
//  Created by mooyumm on 8/26/26.
//

import SafariServices
import os.log

class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {

    func beginRequest(with context: NSExtensionContext) {
        let request = context.inputItems.first as? NSExtensionItem

        let profile: UUID?
        if #available(iOS 17.0, macOS 14.0, *) {
            profile = request?.userInfo?[SFExtensionProfileKey] as? UUID
        } else {
            profile = request?.userInfo?["profile"] as? UUID
        }

        let message: Any?
        if #available(iOS 15.0, macOS 11.0, *) {
            message = request?.userInfo?[SFExtensionMessageKey]
        } else {
            message = request?.userInfo?["message"]
        }

        os_log(.default, "Received inspiration drag message: %@ (profile: %@)", String(describing: message), profile?.uuidString ?? "none")

        if let dictionary = message as? [String: Any] {
            DistributedNotificationCenter.default().post(
                name: Notification.Name("com.mooyumm.InspirationLibrary.browserImageDrag"),
                object: nil,
                userInfo: dictionary
            )
            sendToContainingApp(dictionary) { [weak self] delivered in
                self?.complete(context, delivered: delivered)
            }
        } else {
            complete(context, delivered: false)
        }
    }

    private func complete(_ context: NSExtensionContext, delivered: Bool) {
        let response = NSExtensionItem()
        if #available(iOS 15.0, macOS 11.0, *) {
            response.userInfo = [ SFExtensionMessageKey: [ "ok": delivered ] ]
        } else {
            response.userInfo = [ "message": [ "ok": delivered ] ]
        }
        context.completeRequest(returningItems: [ response ], completionHandler: nil)
    }

    private func sendToContainingApp(_ message: [String: Any], completion: @escaping (Bool) -> Void) {
        guard JSONSerialization.isValidJSONObject(message),
              let body = try? JSONSerialization.data(withJSONObject: message),
              let url = URL(string: "http://127.0.0.1:49158/drag") else {
            completion(false)
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = 1
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        URLSession.shared.dataTask(with: request) { _, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode
            completion(error == nil && status == 200)
        }.resume()
    }

}
