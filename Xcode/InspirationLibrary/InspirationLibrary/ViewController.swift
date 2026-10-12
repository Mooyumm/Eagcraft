//
//  ViewController.swift
//  InspirationLibrary
//
//  Created by mooyumm on 8/26/26.
//

import Cocoa
import SwiftUI
import WebKit

final class ViewController: NSViewController {
    // Storyboard 生成器保留了这个连接；主界面加载后会由 SwiftUI 视图替换。
    @IBOutlet private var webView: WKWebView!

    override func viewDidLoad() {
        super.viewDidLoad()
        view = NSHostingView(rootView: ContentView())
    }
}
