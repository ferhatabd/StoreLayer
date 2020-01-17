//
//  File.swift
//  
//
//  Created by Ferhat Abdullahoglu on 17.01.2020.
//

import Foundation
import StoreKit
import os.log

public typealias ProductIdentifier = String
public typealias ProductsRequestCompletionHandler = (_ success: Bool, _ products: [SKProduct]?, _ error: Error?) -> ()

public protocol IapDelegate: AnyObject
{
    func transactionListDrained()
    func cancelled()
}

public enum IAPStoreErrors: Error {
    case invalidAppId(id: Int)
}

public struct IAPStoreConfifg {
    
    /// Number of days that should be between two rating dialogue prompts
    public var rateAskTimeThreshold: Double = 60
    
    /// Total active duration thereshold for presenting the rating dialogue - user must have achieved at least this much of totalDuration to be eligible to be asked to rate [min]
    public var rateAskDurationThreshold: Double = 25
    
    /// Apple AppID
    public var appleAppId: Int = 0
    
    /// Product identifiers that are currently available on the AppStoe
    public var productIdentifiers: Set<ProductIdentifier> = .init()
    
    /// Last rate interaction date
    public var lastTimeRateAsked = Date()
    
    /// For how long has the user been using the app
    public var userUsageTime: Double = 0
    
    /// User's usage time when the rating was lasted asked
    public var userUsageTimeAtLastRating: Double = 0
    
    /// Sandbox environment i active
    public var sandbox = false
    
    /// Bundle receipt url
    public var receiptUrl = Bundle.main.appStoreReceiptURL
    
    /// Operation should be handled without notifying the user (probably a restore is in progress)
    public var silent = false
    
    /// Receipt validation URL
    public var validationUrl = ""
    
    public init() {}
    
}

open class IAPStore : NSObject  {
    
    
    // MARK: - Properties
    //
    
    
    // MARK: - Private properties
    fileprivate let productIdentifiers: Set<ProductIdentifier>
    fileprivate var productsRequest: SKProductsRequest?
    fileprivate var productsRequestCompletionHandler: ProductsRequestCompletionHandler?
    fileprivate lazy var receiptValidator: ReceiptValidator = {
        var validatorConfig = ReceiptValidationConfig()
        validatorConfig.sandbox = config.sandbox
        validatorConfig.receiptUrl = config.receiptUrl
        validatorConfig.silent = config.silent
        validatorConfig.validationUrl = config.validationUrl
        return ReceiptValidator(withConfig: validatorConfig, withParent: self)
    }()
    fileprivate var isObserving = false
    
    // MARK: - Internal properties
    
    /// Configuration of the store
    internal let config: IAPStoreConfifg
    
    @available(iOS 10.0, *)
    static internal let log = OSLog(subsystem: Bundle.main.bundleIdentifier!, category: "StoreLayer")
    
    // MARK: - Public properties
    
    /// IAP Store purchase notification which can be used to follow up on events
    public static let IAPStorePurchaseNotification = "IAPStorePurchaseNotification"
    
    /// Currently existing products
    public static var products: [SKProduct]?
    
    /// Currently purchased products
    public static var purchasedProductIdentifiers =  Set<ProductIdentifier>()
    
    public var existingProductIdentifiers = Array<ProductIdentifier>()
    
    public weak var delegate: IapDelegate?
    
    
    // MARK: - Initialization
    //
    /// Initialization of the Store with a configuration
    /// - Parameter config: Configuration
    public init(withConfig config: IAPStoreConfifg = IAPStoreConfifg()) {
        self.config = config
        productIdentifiers = self.config.productIdentifiers
        for productIdentifier in productIdentifiers {
            var purchased = false
            
            // TODO: check here later if the product is purchased - get a bit from current app
            #warning("check here later if the product is purchased - get a bit from current app ")
            
            if purchased {
                IAPStore.purchasedProductIdentifiers.insert(productIdentifier)
                print("Previously purchased: \(productIdentifier)")
            } else {
                print("Not purchased: \(productIdentifier)")
            }
        }
        super.init()
        
        if #available(iOS 10.0, *) {
            os_log("Store initialized with %d", log: IAPStore.log, type: .default, productIdentifiers.count)
        }
    }
    
    
    // MARK: - Methods
    //
    
    
    // MARK: - Private methods
    /// remove transaction observer
    private func removeTransactionObserver(_ sender: SKPaymentTransactionObserver) {
        SKPaymentQueue.default().remove(sender)
        isObserving = false
    }
    
    /**
       Check if it's ok to show the rating dialogue to the user
       - parameters:
       - shown at: The date at which the user was asked to rate
       - count: Number of times the user was asked to rate
       - returns: True if it's ok to ask the user to rate, False otherwise
       */
      private func userCanBeAskedToRate(shown at: Date, score: Double) -> Bool {
          // Check first how much the user has been active since the last time he was asked to rate
          let scoreCheck = score - config.userUsageTimeAtLastRating
          guard scoreCheck >= Double(config.rateAskDurationThreshold) * 60 else {return false}
          
          // Check if the threshold of the days between two rating prompts has been reached
          let secondsDiff = TimeInterval(config.rateAskTimeThreshold * 24 * 60 * 60)
          let allowedDate = Date(timeInterval: secondsDiff, since: at)
          
          if allowedDate < Date() {
              return true
          } else {
              return false
          }
      }
    
    // MARK: - Internal methods
    // Purchase delivery
    internal func deliverPurchaseNotification(for identifier: String?) {
        guard let id = identifier else {return}
        DispatchQueue.main.async {
            
            IAPStore.purchasedProductIdentifiers.insert(id)
            let _userInfo = ["productId" : id as Any]
            NotificationCenter.default.post(name: NSNotification.Name(rawValue: IAPStore.IAPStorePurchaseNotification), object: id, userInfo: _userInfo)
            self.delegate?.transactionListDrained()
            
            
        }
    } // end of the deliverPurchaseNotification() method
    
    // MARK: - Public methods
    
    /// Add transaction observer - must be called at AppDidFinishLaunching
    public func addTransactionObserver() {
        if !isObserving {
            SKPaymentQueue.default().add(self)
            isObserving = true
        }
        if #available(iOS 10.0, *) {
            os_log("Observer added", log: IAPStore.log, type: .default)
        }
    }
    
    /// AppStore rating handling
    public func askForRating() {
        if #available(iOS 10.3, *) {
            if userCanBeAskedToRate(shown: config.lastTimeRateAsked, score: config.userUsageTime) {
                SKStoreReviewController.requestReview()
                os_log("User was asked for rating", log: IAPStore.log, type: .default)
            }
        } else {
            // Fallback on earlier versions
        }
    }
    
    /**
     Method for manual redirect to AppStore product page for rating
     - parameters:
     - completion: A completion handler for the higher control in case i
     t needs to be notified about the results
     */
    public func askForRating(completion: ((_ success: Bool) -> Void)?) {
        
        let _url: URL
        
        if #available(iOS 10.3, *) {
            guard let url = URL(string : "itms-apps://itunes.apple.com/app/id\(config.appleAppId)?action=write-review") else {
                completion?(false)
                return
            }
            _url = url
        } else {
            guard let url = URL(string : "itms-apps://itunes.apple.com/app/id\(config.appleAppId)") else {
                completion?(false)
                return
            }
            _url = url
        }
        
        guard #available(iOS 10, *) else {
            completion?(UIApplication.shared.openURL(_url))
            return
        }
        UIApplication.shared.open(_url, options: [.universalLinksOnly : 0], completionHandler: completion)
    }
    
  
} // end of the class implementation

// MARK: - StoreKit API

extension IAPStore {
    
    public func requestProducts(_ completionHandler: @escaping ProductsRequestCompletionHandler) {
        productsRequest?.cancel()
        
        // Check if the products are previously loaded
        if let products = IAPStore.products {
            completionHandler(true,products, nil)
        } else {
            existingProductIdentifiers = Array<ProductIdentifier>() // reset the products set
            productsRequestCompletionHandler = completionHandler
            productsRequest = SKProductsRequest(productIdentifiers: productIdentifiers)
            productsRequest?.delegate = self
            productsRequest?.start()
        }
    }
    
    public func buyProduct(_ product: SKProduct) {
        print("Buying \(product.productIdentifier)...")
        let payment = SKPayment(product: product)
        SKPaymentQueue.default().add(payment)
        
        if #available(iOS 10.0, *) {
            os_log("Started the purhcase...", log: IAPStore.log, type: .default)
        }
        
    }
    
    public func isProductPurchased(_ productIdentifier: ProductIdentifier) -> Bool {
        return false
    }
    
    public class func canMakePayments() -> Bool {
        return SKPaymentQueue.canMakePayments()
    }
    
    // Method to restore previous purchases
    public func restorePurchases() {
        SKPaymentQueue.default().restoreCompletedTransactions()
    }
} // end of the class extension


/* ==================================================== */
/* Conforming to SKProductsRequestDelegate              */
/* ==================================================== */
extension IAPStore: SKProductsRequestDelegate {
    
    public func productsRequest(_ request: SKProductsRequest, didReceive response: SKProductsResponse) {
        print("Loaded list of products...")
        let products = response.products
        IAPStore.products = products
        productsRequestCompletionHandler?(true, products, nil)
        clearRequestAndHandler()
        
        
        for p in products {
            print("Found product: \(p.productIdentifier) \(p.localizedTitle) \(p.price.floatValue)")
            existingProductIdentifiers.append(p.productIdentifier)
        }
        
        if #available(iOS 10.0, *) {
            os_log("Found total: %d", log: IAPStore.log, type: .default, existingProductIdentifiers.count)
        }
    }
    
    public func request(_ request: SKRequest, didFailWithError error: Error) {
        print("Failed to load list of products.")
        print("Error: \(error.localizedDescription)")
        productsRequestCompletionHandler?(false, nil, error)
        clearRequestAndHandler()
        
        if #available(iOS 10.0, *) {
            os_log("Found total: 0", log: IAPStore.log, type: .default)
        }
    }
    
    private func clearRequestAndHandler() {
        productsRequest = nil
        productsRequestCompletionHandler = nil
    }
} // end of the class extension


/* ==================================================== */
/* Implement a payment observer                         */
/* ==================================================== */
extension IAPStore: SKPaymentTransactionObserver {
    public func paymentQueue(_ queue: SKPaymentQueue, updatedTransactions transactions: [SKPaymentTransaction]) {
        var shouldValidateReceipt = false
        for t in transactions {
            switch t.transactionState {
            case .purchased:
                if t == transactions.last {
                    self.complete(transaction: t, isLast: true)
                    //
                    if #available(iOS 10.0, *) {
                        os_log("State Purchased, Last: %d", log: IAPStore.log, type: .default, 1)
                    }
                } else {
                    self.complete(transaction: t, isLast: false)
                    //
                    if #available(iOS 10.0, *) {
                        os_log("State Purchased, Last: %d", log: IAPStore.log, type: .default, 0)
                    }
                }
                shouldValidateReceipt = true
                
            case .failed:
                self.fail(transaction: t)
                if #available(iOS 10.0, *) {
                    guard let error = t.error as? SKError else {
                        os_log("State Failed - no error found", log: IAPStore.log, type: .default)
                        break
                    }
                    os_log("State failed - Description %{public}@", log: IAPStore.log, type: .error, error.localizedDescription)
                    os_log("State failed - error.code.rawValue %d", log: IAPStore.log, type: .error, error.code.rawValue)
                    os_log("State failed - error.errorCode %d", log: IAPStore.log, type: .error, error.errorCode)
                    os_log("State failed - SKError.errorDomain %{public}@", log: IAPStore.log, type: .error, SKError.errorDomain)
                    
                    switch error.code {
                    case .clientInvalid:
                        os_log("State failed - Description %{public}@", log: IAPStore.log, type: .error, ".clientInvalid")
                    case .cloudServiceNetworkConnectionFailed:
                        os_log("State failed - Description %{public}@", log: IAPStore.log, type: .error, ".cloudServiceNetworkConnectionFailed")
                    case .cloudServicePermissionDenied:
                        os_log("State failed - Description %{public}@", log: IAPStore.log, type: .error, ".cloudServicePermissionDenied")
                    case .cloudServiceRevoked:
                        os_log("State failed - Description %{public}@", log: IAPStore.log, type: .error, ".cloudServiceRevoked")
                    case .paymentCancelled:
                        os_log("State failed - Description %{public}@", log: IAPStore.log, type: .error, ".paymentCancelled")
                    case .paymentInvalid:
                        os_log("State failed - Description %{public}@", log: IAPStore.log, type: .error, ".paymentInvalid")
                    case .paymentNotAllowed:
                        os_log("State failed - Description %{public}@", log: IAPStore.log, type: .error, ".paymentNotAllowed")
                    case .storeProductNotAvailable:
                        os_log("State failed - Description %{public}@", log: IAPStore.log, type: .error, ".storeProductNotAvailable")
                    case .unknown:
                        os_log("State failed - Description %{public}@", log: IAPStore.log, type: .error, ".unknown")
                    default:
                        os_log("State failed - Description %{public}@", log: IAPStore.log, type: .error, ".unknown")
                    }
                }
            case .restored:
                if t == transactions.last {
                    self.restore(transaction: t, isLast: true)
                } else {
                    self.restore(transaction: t, isLast: false)
                }
                if #available(iOS 10.0, *) {
                    os_log("State Restored", log: IAPStore.log, type: .default)
                }
            case .deferred:
                if #available(iOS 10.0, *) {
                    os_log("State Deferred", log: IAPStore.log, type: .default)
                }
                break
            case .purchasing:
                break
            }
        } // end of the loop over all transactions
        
    } // end of paymentQueue() implementation
    
    public func paymentQueueRestoreCompletedTransactionsFinished(_ queue: SKPaymentQueue) {   }
    
    
    public func paymentQueue(_ queue: SKPaymentQueue, shouldAddStorePayment payment: SKPayment, for product: SKProduct) -> Bool {
        if IAPStore.canMakePayments() {
            return true
        } else {
            return false
        }
    }
    
    
    
    // Purhcase completed
    private func complete(transaction: SKPaymentTransaction, isLast: Bool) {
        print("complete...")
        deliverPurchaseNotification(for: transaction.payment.productIdentifier)
        SKPaymentQueue.default().finishTransaction(transaction)
        
        if #available(iOS 10.0, *) {
            os_log("Transaction completed", log: IAPStore.log, type: .default)
        }
    }
    
    // Check the transaction complete case
    fileprivate func testTransactionCompleted(at date: Date, for product: String) {
        if validateTransactionDate(date, for: product) {
            deliverPurchaseNotification(for: product)
        }
    }
    
    // Method to restore a previous purchase
    private func restore(transaction: SKPaymentTransaction, isLast: Bool) {
        guard let productIdentifier = transaction.original?.payment.productIdentifier else { return }
        print("restore... \(productIdentifier)")
        deliverPurchaseNotification(for: transaction.payment.productIdentifier)
        SKPaymentQueue.default().finishTransaction(transaction)
        
        if #available(iOS 10.0, *) {
            os_log("Transaction restored", log: IAPStore.log, type: .default)
        }
    }
    
    // Transaction error
    private func fail(transaction: SKPaymentTransaction) {
        print("fail...")
        if let transactionError = transaction.error as NSError? {
            // Do not show any error message to the user if the payment is cancelled
            if transactionError.code != SKError.paymentCancelled.rawValue {
                print("Transaction Error: \(transaction.error?.localizedDescription ?? "no desc") with status: (transactionError.code)")
                NotificationCenter.default.post(name: NSNotification.Name(rawValue: IAPStore.IAPStorePurchaseNotification), object: transactionError)
            } else {
                NotificationCenter.default.post(name: NSNotification.Name(rawValue: IAPStore.IAPStorePurchaseNotification), object: nil)
                delegate?.cancelled()
            }
        }
        SKPaymentQueue.default().finishTransaction(transaction)
        
        if #available(iOS 10.0, *) {
            os_log("Transaction failed", log: IAPStore.log, type: .default)
        }
    } // end of the fail() implementation
    
    
    
    // Get the purchase date and productIdentifier
    // and adjust           TBA -- check this method
    private func validateTransactionDate(_ date: Date, for product: String) -> Bool {
        /*
         // Check for which product to set the key values
         if product == UserData.shared.Keys.Local.keyHasPremiumMonthly {
         UserData.shared.Data.monthlyPremiumExpiresAt = date.timeIntervalSince1970 * 1000
         UserData.shared.saveDefaultData()
         return true
         } else if product == UserData.shared.Keys.Local.keyHasPremiumYearly {
         UserData.shared.Data.yearlyPremiumExpiresAt = date.timeIntervalSince1970 * 1000
         UserData.shared.saveDefaultData()
         return true
         }
         return false
         */
        return true
    }
    
} // end of the class extension


// Helper function inserted by Swift 4.2 migrator.
fileprivate func convertToUIApplicationOpenExternalURLOptionsKeyDictionary(_ input: [String: Any]) -> [UIApplication.OpenExternalURLOptionsKey: Any] {
    return Dictionary(uniqueKeysWithValues: input.map { key, value in (UIApplication.OpenExternalURLOptionsKey(rawValue: key), value)})
}
