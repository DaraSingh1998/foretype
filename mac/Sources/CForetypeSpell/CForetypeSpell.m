#import "CForetypeSpell.h"

static NSString *const FTSpellErrorDomain = @"dev.foretype.spell";

static NSError *FTSpellError(id thrown) {
    NSString *name = [thrown isKindOfClass:NSException.class] ? [thrown name] : NSStringFromClass([thrown class]);
    return [NSError errorWithDomain:FTSpellErrorDomain code:1 userInfo:@{NSLocalizedDescriptionKey: name}];
}

@implementation FTSpellGuard {
    id<FTSpellChecking> _checker;
    NSInteger _tag;
}

- (instancetype)initWithChecker:(id<FTSpellChecking>)checker {
    if ((self = [super init])) {
        @try {
            _checker = checker ?: (id<FTSpellChecking>)NSSpellChecker.sharedSpellChecker;
            _tag = NSSpellChecker.uniqueSpellDocumentTag;
        } @catch (id thrown) {
            NSLog(@"Foretype: no spell checker: %@", FTSpellError(thrown).localizedDescription);
        }
    }
    return self;
}

/// Raises when there is none, inside the callers' @try (a message to nil would answer 0,
/// which reads as misspelled).
- (id<FTSpellChecking>)checker {
    if (!_checker) [NSException raise:@"FTNoSpellChecker" format:@"no spell checker"];
    return _checker;
}

- (NSNumber *)isMisspelled:(NSString *)word error:(NSError **)error {
    @try {
        id<FTSpellChecking> checker = self.checker;
        NSRange r = [checker checkSpellingOfString:word startingAt:0 language:checker.language wrap:NO
                            inSpellDocumentWithTag:_tag wordCount:NULL];
        return @(r.location != NSNotFound);
    } @catch (id thrown) {
        if (error) *error = FTSpellError(thrown);
        return nil;
    }
}

- (NSArray<NSString *> *)completionsOf:(NSString *)fragment error:(NSError **)error {
    @try {
        id<FTSpellChecking> checker = self.checker;
        NSArray<NSString *> *more = [checker completionsForPartialWordRange:NSMakeRange(0, fragment.length)
                                                                   inString:fragment language:checker.language
                                                     inSpellDocumentWithTag:_tag];
        return more ?: @[];
    } @catch (id thrown) {
        if (error) *error = FTSpellError(thrown);
        return nil;
    }
}

- (NSString *)correctionOf:(NSString *)word error:(NSError **)error {
    @try {
        id<FTSpellChecking> checker = self.checker;
        NSString *fix = [checker correctionForWordRange:NSMakeRange(0, word.length) inString:word
                                               language:checker.language inSpellDocumentWithTag:_tag];
        return fix ?: @"";
    } @catch (id thrown) {
        if (error) *error = FTSpellError(thrown);
        return nil;
    }
}

@end

@implementation FTRaisingSpellChecker

- (instancetype)init {
    if ((self = [super init])) {
        _raising = [NSSet set];
        _fix = @"";
    }
    return self;
}

- (void)reached:(NSString *)call {
    _calls += 1;
    if ([_raising containsObject:call]) {
        [NSException raise:@"NSXPCSpellServerTimeoutException" format:@"stand-in for %@", call];
    }
}

- (NSString *)language {
    [self reached:@"language"];
    return @"en";
}

- (NSRange)checkSpellingOfString:(NSString *)string
                      startingAt:(NSInteger)offset
                        language:(NSString *)language
                            wrap:(BOOL)wrap
          inSpellDocumentWithTag:(NSInteger)tag
                       wordCount:(NSInteger *)wordCount {
    [self reached:@"check"];
    return _misspells ? NSMakeRange(0, string.length) : NSMakeRange(NSNotFound, 0);
}

- (NSArray<NSString *> *)completionsForPartialWordRange:(NSRange)range
                                               inString:(NSString *)string
                                               language:(NSString *)language
                                 inSpellDocumentWithTag:(NSInteger)tag {
    [self reached:@"completions"];
    return nil;
}

- (NSString *)correctionForWordRange:(NSRange)range
                            inString:(NSString *)string
                            language:(NSString *)language
                  inSpellDocumentWithTag:(NSInteger)tag {
    [self reached:@"correction"];
    return _fix;
}

@end
