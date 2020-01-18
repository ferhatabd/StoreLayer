//
//  File.swift
//  
//
//  Created by Ferhat Abdullahoglu on 17.01.2020.
//

import Foundation
import UIKit // TBA -- remove UIKit after deleting the temp alerts within endValidation() method
import os.log


/* ==================================================== */
/* Receipt Validation                                   */
/* ==================================================== */
public protocol ReceiptValidationDelegate { // TBA remove alert from the protocol before release
    func endValidation(with action: ReceiptValidationActions, shouldRefresh: Bool, alert: UIAlertController?)
}


// Error enumeration
public enum ReceiptValidatorResults: Int {
    case couldNotFindReceipt = 0
    case errorOnServer = 1
    case receiptInvalid = 2
    case subsExpired = 3
    case subsValid = 4
    case corruptData = 5
    case bundleIdInvalid = 6
    case appleServerDown = 7
    case corruptReceiptData = 8
    case networkError = 9
    case wrongEnviroment = 10
    case secretKeyNotMatch = 11
    case statusUnknown = 12
}

public enum ReceiptValidationActions {
    case tolerate
    case terminate
    case pass
    case reRun
}

public struct ReceiptValidationConfig {
    /// Validation URL to send the receipt to
    public var validationUrl: String = ""
    public var sandbox: Bool = false
    public var silent: Bool = false
    public var receiptUrl = Bundle.main.appStoreReceiptURL
}



public struct ReceiptValidator {
    
    
    // MARK: - Properties
    //
    
    
    // MARK: - Private properties
    
    
    /// Valiadator config
    private let config: ReceiptValidationConfig
    
    private weak var store: IAPStore?
    
    /// Logger
    private static var log: OSLog {
        return OSLog(subsystem: Bundle.main.bundleIdentifier!, category: "RV")
    }
    
    
    // MARK: - Internal properties
    
    /// Flag that tells whether a restore is in progress
    internal var restoreInProgress: Bool = false
    
    /// Notification name
    static internal let restoreNotification = "RestoreNotification"
    
    
    // MARK: - Public properties
    
    /// Validation delegate
    internal var delegate: ReceiptValidationDelegate?
    
    /// Validation results
    internal let dictResults: [ReceiptValidatorResults: ReceiptValidationActions] =
        [
            .subsValid : .pass,
            .errorOnServer : .tolerate,
            .appleServerDown : .tolerate,
            .networkError : .tolerate,
            .statusUnknown : .tolerate,
            .secretKeyNotMatch : .terminate,
            .couldNotFindReceipt : .terminate,
            .receiptInvalid : .terminate,
            .subsExpired : .terminate,
            .corruptData : .terminate,
            .bundleIdInvalid : .terminate,
            .corruptReceiptData : .terminate,
            .wrongEnviroment : .reRun
    ]
    
    // MARK: - Initialization
    //
    public init(withConfig config: ReceiptValidationConfig, withParent parent: IAPStore? = nil) {
        self.config = config
        self.store = parent
    }
    
    
    // MARK: - Methods
    //
    
    
    // MARK: - Private methods
    
    // Check if the receipt is accessible
    private func isReceiptFound() {
        do {
            if let _ = try config.receiptUrl?.checkResourceIsReachable() {
                self.loadReceipt()
            } else {
                self.endValidation(.couldNotFindReceipt)
            }
        } catch {
            self.endValidation(.couldNotFindReceipt)
            
            if #available(iOS 10.0, *) {
                os_log("No R.", log: ReceiptValidator.log, type: .error)
            }
        }
    }
    
    // Try to load the receipt data
    private func loadReceipt() {
        do {
            let receiptData = try Data(contentsOf: config.receiptUrl!)
            self.getReceiptData(receiptData)
        } catch {
            self.endValidation(.couldNotFindReceipt)
        }
    }
    
    // Try to validate the receipt -> check for the response from the server
    private func getReceiptData(_ data: Data) {
        var request = URLRequest(url: URL(string: config.validationUrl)!)
        let session = URLSession.shared
        let dataEncoded = ((data as NSData).base64EncodedString(options: Data.Base64EncodingOptions.endLineWithCarriageReturn)).complyForPhp()
        
        var jsonDict = [String:String]()
        if config.sandbox {
            jsonDict = ["data":dataEncoded, "env":"1"]
        } else {
            jsonDict = ["data":dataEncoded, "env":"0"]
        }
        
        do {
            let jsonData = try JSONSerialization.data(withJSONObject: jsonDict, options: [])
            request.httpMethod = "POST"
            request.httpBody = jsonData
            let _ = session.dataTask(with: request) { (data, response, error) in
                //
                if error != nil || data == nil {
                    session.invalidateAndCancel()
                    self.endValidation(.networkError)
                    print(error?.localizedDescription ?? "")
                    return
                }
                do {
                    let json = try JSONSerialization.jsonObject(with: data!, options: JSONSerialization.ReadingOptions.mutableLeaves)
                    if let jsonData = json as? NSDictionary {
                        session.invalidateAndCancel()
                        self.validateReceiptData(jsonData)
                    }
                } catch {
                    print(error)
                    session.invalidateAndCancel()
                    self.endValidation(.errorOnServer)
                    
                    if #available(iOS 10.0, *) {
                        os_log("serialization failure", log: ReceiptValidator.log, type: .error)
                    }
                }
            }.resume()
        } catch  {
            print(error)
            session.invalidateAndCancel()
            
            if #available(iOS 10.0, *) {
                os_log("session failure", log: ReceiptValidator.log, type: .error)
            }
        }
    } // end of the getReceiptData()
    
    
    // Get the response data and check for the results
    fileprivate func validateReceiptData(_ data: NSDictionary) {
        // check first the status
        if let s = data["status"] as? Int64 {
            let status = s
            print(status)
            if status == 0 { // receipt is valid -> continue checking
                // do nothing
            } else if status == 21000 {
                self.endValidation(.appleServerDown)
                return
            } else if status == 21002 {
                self.endValidation(.corruptReceiptData)
                return
            } else if status == 21003 {
                self.endValidation(.receiptInvalid)
                return
            } else if status == 21004 { // normally should be returned only for iOS6 style receipts - but it means secret key is not correct -> terminate
                self.endValidation(.secretKeyNotMatch)
                return
            } else if status == 21005 {
                self.endValidation(.appleServerDown)
                return
            } else if status == 21006 {
                self.endValidation(.subsExpired)
                return
            } else if status == 21007 { // sandbox receipt sent to production
                self.endValidation(.wrongEnviroment)
                return
            } else { // unknown status -> add this one to the tolerate list
                self.endValidation(.statusUnknown)
                return
            }
        }
        
        let step = 0
        // -----------------------------------
        // Carry out the validation steps
        // -----------------------------------
        switch step {
        case 0:
            // if we are here the first step is already checked
            fallthrough
        case 1:
            // check the signature
            fallthrough
        case 2:
            // check the CFBundleIdentifier
            guard let receipt = data["receipt"] as? NSDictionary else {self.endValidation(.corruptData); return}
            guard let bundleIdOn = receipt["bundle_id"] as? String else {self.endValidation(.corruptData); return}
            if let bundleIdOff = Bundle.main.infoDictionary?["CFBundleIdentifier"] as? String {
                if bundleIdOn != bundleIdOff {
                    self.endValidation(.bundleIdInvalid)
                    break;
                } else {
                    fallthrough
                }
            } else {
                self.endValidation(.corruptData)
            }
        case 3:
            // check the app version
            fallthrough
        case 4:
            // check the expiration date
            if let receipt = data["receipt"] as? NSDictionary,
                let in_app = receipt["in_app"] as? [NSDictionary] {
                
                print("Current time is: \(Date().timeIntervalSince1970 * 1000)")
                
                if validPremiumMonthly || validPremiumYearly {
                    self.endValidation(.subsValid)
                } else {
                    self.endValidation(.subsExpired)
                }
            }
            break
        default:
            break
        }
        // -----------------------------------
    }
    
    
    // Goes over an array of NSDictionary and returns an array of objects which matches the requested data
    private func getElementsFromDict(_ from: [NSDictionary], which key: String, matching data: String) -> [NSDictionary]? {
        var resultFound = false
        var result = Array<NSDictionary>()
        for p in from {
            if let p_id = p[key] as? String {
                if p_id == data {
                    result.append(p)
                    resultFound = true
                }
            }
        }
        
        // Check if anything has been found
        if resultFound {
            return result
        } else {
            return nil
        }
    } // end of getElementsFromDict()
    
    
    // Gets an array of dictionary and checks all the expiration dates
    // in it -> then it compares the greates expiry date with the current
    // time to return true if not expired
    private func checkExpire(_ products: [NSDictionary]) -> Bool {
        let greatestExpireDate = getExpire(products)
        //
        print(Date().timeIntervalSince1970 * 1000)
        if greatestExpireDate < Date().timeIntervalSince1970 * 1000 {
            return false
        } else {
            return true
        }
    } // end of checkExpire()
    
    
    // Get the greatest expiration time from the array
    private func getExpire(_ products: [NSDictionary]) -> Double {
        var greatestExpireDate: Double = 0
        for p in products {
            if let e = p["expires_date_ms"] as? String,
                let expire = Double(e) {
                if expire > greatestExpireDate {
                    greatestExpireDate = expire
                }
            }
        }
        
        return greatestExpireDate
    } // end of getExpire()
    
    // Finish the validation process with the given result
    private func endValidation(_ result: ReceiptValidatorResults)
    {
        
        guard let action = dictResults[result] else {
            self.delegate?.endValidation(with: .tolerate, shouldRefresh: false, alert: nil)
            return
        }
        
        
        if #available(iOS 10.0, *) {
            os_log("result available", log: ReceiptValidator.log, type: .default)
        }
        
        // TBA -- only for test purposes
        var alert: UIAlertController!
        if result == .subsExpired && !restoreInProgress {
            //            alert = UIAlertController(title: ":(", message: "Premium expired", preferredStyle: .alert)
        } else if result == .subsExpired && restoreInProgress && !config.silent {
            alert = UIAlertController(title: "⛔️", message: "No valid purchase to restore", preferredStyle: .alert)
        } else if result == .corruptReceiptData {
            //            alert = UIAlertController(title: ":(", message: "Corrupt receipt", preferredStyle: .alert)
        } else if result == .subsValid && !restoreInProgress {
            //            alert = UIAlertController(title: ":)", message: "Premium OK", preferredStyle: .alert)
        } else if result == .subsValid && restoreInProgress && !config.silent {
            alert = UIAlertController(title: "✅", message: "Last purchase is restored", preferredStyle: .alert)
        }
        
        // Check if a restore was in progress
        if restoreInProgress {
            NotificationCenter.default.post(name: NSNotification.Name(rawValue: ReceiptValidator.restoreNotification), object: nil)
        }
        
        switch result {
        case .corruptReceiptData:
            self.delegate?.endValidation(with: action, shouldRefresh: true, alert: alert)
        default:
            self.delegate?.endValidation(with: action, shouldRefresh: false, alert: alert)
        }
        
        if alert != nil {
            if #available(iOS 10.0, *) {
                os_log("result with fault %d", log: ReceiptValidator.log, type: .error, result.rawValue)
            }
        }
    } // end of endValidation()
    
    // MARK: - Public methods
    
    // Start the validation process
    public func start() {
        // check first if the URL was found
        if config.receiptUrl != nil {
            // check if the receipt can be located
            self.isReceiptFound()
        } else {
            self.endValidation(.couldNotFindReceipt)
            
            if #available(iOS 10.0, *) {
                os_log("no R.", log: ReceiptValidator.log, type: .error)
            }
        }
    }
    
}


/* ==================================================== */
/* Extension to String to remove \n \r & +              */
/* ==================================================== */
internal extension String
{
    func complyForPhp() -> String {
        var stream = self
        //stream = stream.replacingOccurrences(of: "+", with: "%2B")
        stream = stream.replacingOccurrences(of: "\n", with: "")
        stream = stream.replacingOccurrences(of: "\r", with: "")
        return stream
    }
    
    /**
     Method to strip ".", "$", "#", "[", "]" chars from a string
     */
    func complyForFb() -> String {
        var _stream = self
        
        _stream = _stream.replacingOccurrences(of: ".", with: "")
        _stream = _stream.replacingOccurrences(of: "$", with: "")
        _stream = _stream.replacingOccurrences(of: "[", with: "")
        _stream = _stream.replacingOccurrences(of: "]", with: "")
        _stream = _stream.replacingOccurrences(of: "#", with: "")
        
        return _stream
    }
}

