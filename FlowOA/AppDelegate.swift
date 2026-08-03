//
//  AppDelegate.swift
//  公文流转 · iOS 版
//

import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {

        window = UIWindow(frame: UIScreen.main.bounds)
        let root = ViewController()
        window?.rootViewController = root
        window?.backgroundColor = .white
        window?.makeKeyAndVisible()

        return true
    }
}
