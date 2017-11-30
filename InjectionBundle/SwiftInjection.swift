//
//  SwiftInjection.swift
//  InjectionBundle
//
//  Created by John Holdsworth on 05/11/2017.
//  Copyright © 2017 John Holdsworth. All rights reserved.
//
//  $Id: //depot/ResidentEval/InjectionBundle/SwiftInjection.swift#26 $
//
//  Cut-down version of code injection in Swift. Uses code
//  from SwiftEval.swift to recompile and reload class.
//

#if arch(x86_64) // simulator/macOS only
import Foundation
import XCTest

@objc public protocol SwiftInjected {
    @objc optional func injected()
}

#if os(iOS) || os(tvOS)
import UIKit

extension UIViewController {

    /// inject a UIView controller and redraw
    public func injectVC() {
        inject()
        for subview in self.view.subviews {
            subview.removeFromSuperview()
        }
        if let sublayers = self.view.layer.sublayers {
            for sublayer in sublayers {
                sublayer.removeFromSuperlayer()
            }
        }
        viewDidLoad()
    }
}
#else
import Cocoa
#endif

extension NSObject {

    public func inject() {
        if let oldClass: AnyClass = object_getClass(self) {
            SwiftInjection.inject(oldClass: oldClass, classNameOrFile: "\(oldClass)")
        }
    }

    @objc
    public class func inject(file: String) {
        let path = URL(fileURLWithPath: file).deletingPathExtension().path
        SwiftInjection.inject(oldClass: nil, classNameOrFile: String(path.dropFirst()))
    }
}

@objc
public class SwiftInjection: NSObject {

    static let testQueue = DispatchQueue(label: "INTestQueue")

    static func inject(oldClass: AnyClass?, classNameOrFile: String) {
        do {
            let tmpfile = try SwiftEval.instance.rebuildClass(oldClass: oldClass,
                                                              classNameOrFile: classNameOrFile, extra: nil)
            try inject(tmpfile: tmpfile)
        }
        catch {
        }
    }

    @objc
    public class func inject(tmpfile: String) throws {
        let newClasses = try SwiftEval.instance.linkAndInject(tmpfile: tmpfile)
        let oldClasses = //oldClass != nil ? [oldClass!] :
            newClasses.map { objc_getClass(class_getName($0)) as! AnyClass }
        var testClasses = [AnyClass]()
        for i in 0..<oldClasses.count {
            let oldClass: AnyClass = oldClasses[i], newClass: AnyClass = newClasses[i]

            // old-school swizzle Objective-C class & instance methods
            injection(swizzle: object_getClass(newClass), onto: object_getClass(oldClass))
            injection(swizzle: newClass, onto: oldClass)

            // overwrite Swift vtable of existing class with implementations from new class
            let existingClass = unsafeBitCast(oldClass, to: UnsafeMutablePointer<ClassMetadataSwift>.self)
            let classMetadata = unsafeBitCast(newClass, to: UnsafeMutablePointer<ClassMetadataSwift>.self)

            // Swift equivalent of Swizzling
            if (classMetadata.pointee.Data & 0x1) == 1 {
                if classMetadata.pointee.ClassSize != existingClass.pointee.ClassSize {
                    NSLog("\(oldClass) metadata size changed. Did you add a method?")
                }

                func byteAddr<T>(_ location: UnsafeMutablePointer<T>) -> UnsafeMutablePointer<UInt8> {
                    return location.withMemoryRebound(to: UInt8.self, capacity: 1) { $0 }
                }

                let vtableOffset = byteAddr(&existingClass.pointee.IVarDestroyer) - byteAddr(existingClass)
                let vtableLength = Int(existingClass.pointee.ClassSize -
                    existingClass.pointee.ClassAddressPoint) - vtableOffset

                print("Injected '\(NSStringFromClass(oldClass))', vtable length: \(vtableLength)")
                memcpy(byteAddr(existingClass) + vtableOffset,
                       byteAddr(classMetadata) + vtableOffset, vtableLength)
            }

            if newClass.isSubclass(of: XCTestCase.self) {
                testClasses.append(newClass)
//                    if ( [newClass isSubclassOfClass:objc_getClass("QuickSpec")] )
//                    [[objc_getClass("_TtC5Quick5World") sharedWorld]
//                    setCurrentExampleMetadata:nil];
            }

            // implement -injected() method using sweep of objects in application
            else if class_getInstanceMethod(oldClass, #selector(SwiftInjected.injected)) != nil {
                #if os(iOS) || os(tvOS)
                let app = UIApplication.shared
                #else
                let app = NSApplication.shared
                #endif
                let seeds: [Any] =  [app.delegate as Any] + app.windows
                SwiftSweeper(instanceTask: {
                    (instance: AnyObject) in
                    if object_getClass(instance) == oldClass {
                        let proto = unsafeBitCast(instance, to: SwiftInjected.self)
                        proto.injected?()
                    }
                }).sweepValue(seeds)
            }
        }

        // Thanks https://github.com/johnno1962/injectionforxcode/pull/234
        if !testClasses.isEmpty {
            testQueue.async {
                testQueue.suspend()
                let timer = Timer(timeInterval: 0, repeats:false, block: { _ in
                    for newClass in testClasses {
                        let suite0 = XCTestSuite(name: "Injected")
                        let suite = XCTestSuite(forTestCaseClass: newClass)
                        let tr = XCTestSuiteRun(test: suite)
                        suite0.addTest(suite)
                        suite0.perform(tr)
                    }
                    testQueue.resume()
                })
                RunLoop.main.add(timer, forMode: RunLoopMode.commonModes)
            }
        }
        else {
            let notification = Notification.Name("INJECTION_BUNDLE_NOTIFICATION")
            NotificationCenter.default.post(name: notification, object: oldClasses)
        }
    }

    static func injection(swizzle newClass: AnyClass?, onto oldClass: AnyClass?) {
        var methodCount: UInt32 = 0
        if let methods = class_copyMethodList(newClass, &methodCount) {
            for i in 0 ..< Int(methodCount) {
                class_replaceMethod(oldClass, method_getName(methods[i]),
                                    method_getImplementation(methods[i]),
                                    method_getTypeEncoding(methods[i]))
            }
            free(methods)
        }
    }
}

class SwiftSweeper {

    static var current: SwiftSweeper?

    let instanceTask: (AnyObject) -> Void
    var seen = [UnsafeRawPointer: Bool]()

    init(instanceTask: @escaping (AnyObject) -> Void) {
        self.instanceTask = instanceTask
        SwiftSweeper.current = self
    }

    func sweepValue(_ value: Any) {
        let mirror = Mirror(reflecting: value)
        if var style = mirror.displayStyle {
            if _typeName(mirror.subjectType).hasPrefix("Swift.ImplicitlyUnwrappedOptional<") {
                style = .optional
            }
            switch style {
            case .set:
                fallthrough
            case .collection:
                for (_, child) in mirror.children {
                    sweepValue(child)
                }
                return
            case .dictionary:
                for (_, child) in mirror.children {
                    for (_, element) in Mirror(reflecting: child).children {
                        sweepValue(element)
                    }
                }
                return
            case .class:
                sweepInstance(value as AnyObject)
                return
            case .optional:
                if let some = mirror.children.first?.value {
                    sweepValue(some)
                }
                return
            case .enum:
                if let evals = mirror.children.first?.value {
                    sweepValue(evals)
                }
            case .tuple:
                fallthrough
            case .struct:
                sweepMembers(value)
            }
        }
    }

    func sweepInstance(_ instance: AnyObject) {
        let reference = unsafeBitCast(instance, to: UnsafeRawPointer.self)
        if seen[reference] == nil {
            seen[reference] = true

            instanceTask(instance)

            sweepMembers(instance)
            instance.legacySwiftSweep?()
        }
    }

    func sweepMembers(_ instance: Any) {
        var mirror: Mirror? = Mirror(reflecting: instance)
        while mirror != nil {
            for (_, value) in mirror!.children {
                sweepValue(value)
            }
            mirror = mirror!.superclassMirror
        }
    }
}

extension NSObject {
    @objc func legacySwiftSweep() {
        var icnt: UInt32 = 0, cls: AnyClass? = object_getClass(self)!
        let object = "@".utf16.first!
        while cls != nil && cls != NSObject.self && cls != NSURL.self {
            #if os(OSX)
            let className = NSStringFromClass(cls!)
            if cls != NSWindow.self && className.starts(with: "NS") {
                return
            }
            #endif
            if let ivars = class_copyIvarList(cls, &icnt) {
                for i in 0 ..< Int(icnt) {
                    if let type = ivar_getTypeEncoding(ivars[i]), type[0] == object {
                        (unsafeBitCast(self, to: UnsafePointer<Int8>.self) + ivar_getOffset(ivars[i]))
                            .withMemoryRebound(to: AnyObject?.self, capacity: 1) {
                                if let obj = $0.pointee {
                                    SwiftSweeper.current?.sweepInstance(obj)
                                }
                        }
                    }
                }
                free(ivars)
            }
            cls = class_getSuperclass(cls)
        }
    }
}

extension NSSet {
    @objc override func legacySwiftSweep() {
        self.forEach { SwiftSweeper.current?.sweepInstance($0 as AnyObject) }
    }
}

extension NSArray {
    @objc override func legacySwiftSweep() {
        self.forEach { SwiftSweeper.current?.sweepInstance($0 as AnyObject) }
    }
}

extension NSDictionary {
    @objc override func legacySwiftSweep() {
        self.allValues.forEach { SwiftSweeper.current?.sweepInstance($0 as AnyObject) }
    }
}

/**
 Layout of a class instance. Needs to be kept in sync with ~swift/include/swift/Runtime/Metadata.h
 */
public struct ClassMetadataSwift {

    public let MetaClass: uintptr_t = 0, SuperClass: uintptr_t = 0
    public let CacheData1: uintptr_t = 0, CacheData2: uintptr_t = 0

    public let Data: uintptr_t = 0

    /// Swift-specific class flags.
    public let Flags: UInt32 = 0

    /// The address point of instances of this type.
    public let InstanceAddressPoint: UInt32 = 0

    /// The required size of instances of this type.
    /// 'InstanceAddressPoint' bytes go before the address point;
    /// 'InstanceSize - InstanceAddressPoint' bytes go after it.
    public let InstanceSize: UInt32 = 0

    /// The alignment mask of the address point of instances of this type.
    public let InstanceAlignMask: UInt16 = 0

    /// Reserved for runtime use.
    public let Reserved: UInt16 = 0

    /// The total size of the class object, including prefix and suffix
    /// extents.
    public let ClassSize: UInt32 = 0

    /// The offset of the address point within the class object.
    public let ClassAddressPoint: UInt32 = 0

    /// An out-of-line Swift-specific description of the type, or null
    /// if this is an artificial subclass.  We currently provide no
    /// supported mechanism for making a non-artificial subclass
    /// dynamically.
    public let Description: uintptr_t = 0

    /// A function for destroying instance variables, used to clean up
    /// after an early return from a constructor.
    public var IVarDestroyer: SIMP? = nil

    // After this come the class members, laid out as follows:
    //   - class members for the superclass (recursively)
    //   - metadata reference for the parent, if applicable
    //   - generic parameters for this class
    //   - class variables (if we choose to support these)
    //   - "tabulated" virtual methods

}

/** pointer to a function implementing a Swift method */
public typealias SIMP = @convention(c) (_: AnyObject) -> Void
#endif
