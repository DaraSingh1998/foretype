// NSSpellChecker raises Objective-C exceptions (NSXPCSpellServerTimeoutException when the
// spell server stalls), and Swift cannot catch them: one unwinding through Swift frames
// crashes the app, or is swallowed by HIServices inside an AXObserver callback. Every call
// to the checker therefore happens here, in Objective-C, inside @try; no Swift frame is
// ever between the throw and the @catch, so a Swift closure run from a @try would not do.
#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// The NSSpellChecker calls `Speller` needs. The self-test's stand-in answers them too.
@protocol FTSpellChecking <NSObject>
- (NSString *)language;
- (NSRange)checkSpellingOfString:(NSString *)string
                      startingAt:(NSInteger)offset
                        language:(nullable NSString *)language
                            wrap:(BOOL)wrap
          inSpellDocumentWithTag:(NSInteger)tag
                       wordCount:(nullable NSInteger *)wordCount;
- (nullable NSArray<NSString *> *)completionsForPartialWordRange:(NSRange)range
                                                        inString:(NSString *)string
                                                        language:(nullable NSString *)language
                                          inSpellDocumentWithTag:(NSInteger)tag;
- (nullable NSString *)correctionForWordRange:(NSRange)range
                                     inString:(NSString *)string
                                     language:(nullable NSString *)language
                       inSpellDocumentWithTag:(NSInteger)tag;
@end

/// The checker's calls with exceptions turned into errors (`throws` in Swift), in its current
/// language. An error means "not checked", never an answer. It names the exception, not its
/// reason, so a word can't reach the log.
@interface FTSpellGuard : NSObject
/// `checker` nil is the shared NSSpellChecker with a document tag of its own.
- (instancetype)initWithChecker:(nullable id<FTSpellChecking>)checker NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
- (nullable NSNumber *)isMisspelled:(NSString *)word error:(NSError **)error;
/// Empty when there are none.
- (nullable NSArray<NSString *> *)completionsOf:(NSString *)fragment error:(NSError **)error;
/// Empty when there is none.
- (nullable NSString *)correctionOf:(NSString *)word error:(NSError **)error;
@end

/// A checker that raises from the calls named in `raising` ("language", "check",
/// "completions", "correction"), as the spell server does, for `--speller-selftest`. It lives
/// here because a Swift method that raises would itself unwind through a Swift frame.
@interface FTRaisingSpellChecker : NSObject <FTSpellChecking>
@property (nonatomic, copy) NSSet<NSString *> *raising;
/// Calls that reached the checker.
@property (nonatomic) NSInteger calls;
/// The answers when not raising: every word misspelled, with no completions, corrected to this.
@property (nonatomic) BOOL misspells;
@property (nonatomic, copy) NSString *fix;
@end

NS_ASSUME_NONNULL_END
