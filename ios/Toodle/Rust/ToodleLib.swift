///* This Source Code Form is subject to the terms of the Mozilla Public
// * License, v. 2.0. If a copy of the MPL was not distributed with this
// * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Foundation
import UIKit

protocol Observing {
    // define functions for store observation
    func transactionDidOccur(key: String, reports: [TxReport])
}

protocol Observable {
    func register(key: String, observer: Observing, attributes: [String])
    func unregister(key: String)
}

class ToodleLib {

    var observers: [String: Observing]

    class var sharedInstance: ToodleLib {
        struct Static {
            static let instance: ToodleLib = ToodleLib()
        }
        return Static.instance
    }

    var raw: OpaquePointer

    required init(raw: OpaquePointer) {
        self.raw = raw
        self.observers = [:]
    }

    func intoRaw() -> OpaquePointer {
        return self.raw
    }

    convenience init() {
        let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        let documentsURL = paths[0]
        let storeURI = documentsURL.appendingPathComponent("todolist.db", isDirectory: false).absoluteString

        self.init(raw: new_toodle(storeURI))
    }

    deinit {
        toodle_destroy(raw)
    }

    fileprivate func toPointerArray(list: [RustObject]) -> OpaquePointer {
        var pointerArray = list.map({ $0.intoRaw() })
        return OpaquePointer(AutoreleasingUnsafeMutablePointer<[OpaquePointer]>(&pointerArray))
    }

    func allItems() -> [Item] {
        let items = toodle_get_all_items(self.raw)
        var allItems: [Item] = []
        for index in 0..<item_list_count(items) {
            let item = Item(raw: item_list_entry_at(items, Int(index))!)
            allItems.append(item)
        }
        return allItems
    }

    func createLabel(withName name: String, color: UIColor) -> Label {
        return Label(raw: toodle_create_label(self.raw, name, color.toHex()!))
    }

    func createItem(withName name: String, dueDate: Date?, completionDate: Date?, labels: [Label]) -> Item? {
        var dd: UnsafeMutablePointer<Int64>? = nil
        if let due = dueDate {
            var d = due.asInt64Timestamp()
            dd = UnsafeMutablePointer<Int64>(&d)
        }

        if let item_raw = toodle_create_item(self.raw, name, dd) {
            return Item(raw: item_raw)
        }

        return nil
    }

    func item(withUuid uuid: String) -> Item? {
        guard let new_item = toodle_item_for_uuid(self.raw, uuid) else {
            return nil
        }
        return Item(raw: new_item)
    }

    func update(item: Item, name: String, dueDate: Date?, completionDate: Date?, labels: [Label]) {
        var dd: AutoreleasingUnsafeMutablePointer<Int64>? = nil
        if let due = dueDate{
            var d = due.asInt64Timestamp()
            dd = AutoreleasingUnsafeMutablePointer<Int64>(&d)
        }
        var cd: AutoreleasingUnsafeMutablePointer<Int64>? = nil
        if let completion = completionDate {
            var c = completion.asInt64Timestamp()
            cd = AutoreleasingUnsafeMutablePointer<Int64>(&c)
        }
        var pointerArray = self.toPointerArray(list: labels as [RustObject])
        if let uuid = item.uuid {
            toodle_update_item_by_uuid(self.raw, uuid, name, dd, cd)
        } else {
            toodle_update_item(self.raw,
                               item.raw,
                               name,
                               dd,
                               cd,
                               UnsafeMutablePointer<OpaquePointer>(&pointerArray))
        }
    }

    func entidForAttribute(attribute: String) -> Int64 {
        return Int64(store_entid_for_attribute(self.raw, attribute))
    }
}

extension ToodleLib: Observable {
    func register(key: String, observer: Observing, attributes: [String]) {
//        let ownedPointer = UnsafeMutableRawPointer(Unmanaged.passRetained(self).toOpaque())
//        let wrapper = TmpCallback(
//            obj: ownedPointer,
//            destroy: destroy,
//            callback_fn: callbackDidCallBack)
//        callback(wrapper)
        print("Register \(key)")

        let attrEntIds = attributes.map({ Int64(self.entidForAttribute(attribute: $0)) })

        let ptr = UnsafeMutablePointer<Int64>.allocate(capacity: attrEntIds.count)
        let entidPointer = UnsafeMutableBufferPointer(start: ptr, count: attrEntIds.count)
        var _ = entidPointer.initialize(from: attrEntIds)
        guard let firstElement = entidPointer.baseAddress else {
            return
        }

        print("registering attributes \(attrEntIds)")
//        var attributeLen = UInt64(attributes.count)
//        var attributeList = AttributeList(
//            attributes: ,
//            len: &attributeLen)

        self.observers[key] = observer
        let ownedPointer = UnsafeMutableRawPointer(Unmanaged.passRetained(self).toOpaque())
        let wrapper = RustCallback(
            obj: ownedPointer,
            destroy: destroy,
            callback_fn: transactionObserverCallback)
//        let attrPointer = UnsafeMutablePointer<Int64>(&firstElement)
        store_register_observer(self.raw, key, firstElement, Int64(attributes.count), wrapper)

    }

    func unregister(key: String) {
        print("Unregister \(key)")
        store_unregister_observer(self.raw, key)
        print("\(key) unregistered")
    }

    func transactionObserverCalled(key: String, reports: [TxReport]) {
        let observer = self.observers[key]
        observer?.transactionDidOccur(key: key, reports: reports)
    }
}

class Singleton {
}

private func transactionObserverCallback(obj: UnsafeMutableRawPointer, key: UnsafePointer<CChar>, reports: UnsafePointer<TxReportList>) {
    DispatchQueue.global(qos: .background).async {
        let store: ToodleLib = Unmanaged.fromOpaque(UnsafeRawPointer(obj)).takeUnretainedValue()
        let len = Int(reports.pointee.len)
        var txReports = [TxReport]()
        for i in 0..<len {
            let raw = tx_report_list_entry_at(reports, i)
            let report = TxReport(raw: raw!)
            txReports.append(report)
        }

        store.transactionObserverCalled(key: String(cString: key), reports: txReports)
    }
}

private func destroy(obj: UnsafeMutableRawPointer) {
    print("Destroy was called")
    let _ = Unmanaged<AnyObject>.fromOpaque(UnsafeRawPointer(obj)).takeRetainedValue()
}
