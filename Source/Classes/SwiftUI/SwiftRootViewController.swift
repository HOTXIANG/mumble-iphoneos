// 文件: SwiftRootViewController.swift (正确的内容)

#if os(iOS)
import UIKit
import SwiftUI

private let MUIOSImmersiveStatusBarVisibilityDidChangeNotification =
    Notification.Name("MUIOSImmersiveStatusBarVisibilityDidChangeNotification")

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
        view.backgroundColor = .clear
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: false)
    }
    
    override var preferredStatusBarStyle: UIStatusBarStyle {
        return .default
    }
}

// --- Wrapper 部分保持不变 ---
@objc class SwiftRootViewControllerWrapper: UIViewController {
    private var hostingController: SwiftRootViewController!
    private var shouldHideStatusBar = false
    
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
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleImmersiveStatusBarVisibilityNotification(_:)),
            name: MUIOSImmersiveStatusBarVisibilityDidChangeNotification,
            object: nil
        )
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    @objc
    private func handleImmersiveStatusBarVisibilityNotification(_ notification: Notification) {
        let shouldHide = (notification.object as? Bool) ?? false
        guard shouldHideStatusBar != shouldHide else { return }
        shouldHideStatusBar = shouldHide
        setNeedsStatusBarAppearanceUpdate()
        navigationController?.setNeedsStatusBarAppearanceUpdate()
        hostingController?.setNeedsStatusBarAppearanceUpdate()
    }
    
    override var preferredStatusBarStyle: UIStatusBarStyle {
        return .default
    }
    
    override var prefersStatusBarHidden: Bool {
        return shouldHideStatusBar
    }
    
    override var preferredStatusBarUpdateAnimation: UIStatusBarAnimation {
        return .fade
    }
}
#endif // os(iOS)
