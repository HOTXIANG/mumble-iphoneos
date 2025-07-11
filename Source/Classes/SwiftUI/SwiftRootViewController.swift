// 文件: SwiftRootViewController.swift (正确的内容)

import UIKit
import SwiftUI

// --- 核心修改：将 rootView 修改为 AppRootView ---
class SwiftRootViewController: UIHostingController<AppRootView> {
    
    init() {
        super.init(rootView: AppRootView())
    }
    
    @objc required dynamic init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        navigationController?.setNavigationBarHidden(true, animated: false)
        overrideUserInterfaceStyle = .dark
        view.backgroundColor = .clear
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: false)
    }
    
    override var preferredStatusBarStyle: UIStatusBarStyle {
        return .lightContent
    }
}

// --- Wrapper 部分保持不变 ---
@objc class SwiftRootViewControllerWrapper: UIViewController {
    private var hostingController: SwiftRootViewController!
    
    @objc override init(nibName nibNameOrNil: String?, bundle nibBundleOrNil: Bundle?) {
        super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)
        setupHostingController()
    }
    
    @objc required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupHostingController()
    }
    
    @objc convenience init() {
        self.init(nibName: nil, bundle: nil)
    }
    
    private func setupHostingController() {
        hostingController = SwiftRootViewController()
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        overrideUserInterfaceStyle = .dark
        view.backgroundColor = .clear
        addChild(hostingController)
        view.addSubview(hostingController.view)
        hostingController.didMove(toParent: self)
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hostingController.view.topAnchor.constraint(equalTo: view.topAnchor),
            hostingController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hostingController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hostingController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }
    
    override var preferredStatusBarStyle: UIStatusBarStyle {
        return .lightContent
    }
    
    override var prefersStatusBarHidden: Bool {
        return false
    }
}
