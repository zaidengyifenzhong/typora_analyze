// bypass.m — Typora 1.14.15 license flags override (arm64 / x86_64)
// 参考 X1lyS/typroa_cracked 的注入思路，做以下修正：
//   1) readLicenseInfo 返回值是 id，swizzle 后必须原样返回，否则 start 里 movq 0x8(%rbx),%rdi
//      会拿到垃圾指针；
//   2) 不轮询 RunLoop：vm 加载一次就够，JS 注入只在 didFinishLaunching + 少量重试；
//   3) 同时兜住 unfillLicense 路径，避免移除授权后 hasLicense 被写回 false；
//   4) _options.hasLicense / File.option.hasLicense 只做 UI 兜底，真值仍来自原生 _hasLicense。
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <AppKit/AppKit.h>

static IMP gOrigReadLicenseInfo = NULL;
static IMP gOrigUnfillLicense = NULL;
static IMP gOrigEvaluateJS = NULL;
static BOOL gPatched = NO;

// ---- hasLicense: 恒真 ----
static BOOL sw_hasLicense(id self, SEL _cmd) {
    (void)self; (void)_cmd;
    id d = nil;
    @try { d = [self valueForKey:@"licenseDict"]; } @catch (__unused NSException *e) {}
    return YES;
}

// ---- readLicenseInfo: 跑原实现拿回 dict，再强写 _hasLicense ----
static id sw_readLicenseInfo(id self, SEL _cmd) {
    id r = nil;
    if (gOrigReadLicenseInfo) {
        r = ((id (*)(id, SEL))gOrigReadLicenseInfo)(self, _cmd);
    }
    @try {
        [self setValue:@YES forKey:@"hasLicense"];
        id dict = [self valueForKey:@"licenseDict"];
        if ([dict isKindOfClass:[NSDictionary class]]) {
            NSMutableDictionary *m = [dict mutableCopy];
            if (!m[@"license"]) m[@"license"] = @"LOCAL-FAKE-CODE";
            if (!m[@"email"])   m[@"email"]   = @"local@localhost";
            [self setValue:m forKey:@"licenseDict"];
        }
    } @catch (NSException *e) {
    }
    return r;
}

// ---- unfillLicense: 允许它清 dict，但保留 hasLicense = YES ----
static void sw_unfillLicense(id self, SEL _cmd) {
    if (gOrigUnfillLicense) ((void (*)(id, SEL))gOrigUnfillLicense)(self, _cmd);
    @try {
        [self setValue:@YES forKey:@"hasLicense"];
    } @catch (__unused NSException *e) {}
    // 通知 JS 侧重画
    SEL s = sel_registerName("postNotification");
    if ((IMP)objc_msgSend != NULL && [self respondsToSelector:s]) {
        ((void (*)(id, SEL))objc_msgSend)(self, s);
    }
}

// ---- WKWebView evaluateJavaScript 兜底: hasLicense=false -> true ----
static void sw_evaluateJS(id self, SEL _cmd, NSString *js, id handler) {
    if ([js isKindOfClass:[NSString class]]) {
        if ([js rangeOfString:@"hasLicense=false"].location != NSNotFound ||
            [js rangeOfString:@"hasLicense = false"].location != NSNotFound) {
            js = [js stringByReplacingOccurrencesOfString:@"hasLicense=false"
                                               withString:@"hasLicense=true "];
            js = [js stringByReplacingOccurrencesOfString:@"hasLicense = false"
                                               withString:@"hasLicense = true "];
        }
    }
    if (gOrigEvaluateJS) ((void (*)(id, SEL, id, id))gOrigEvaluateJS)(self, _cmd, js, handler);
}

static void installSwizzles(void) {
    if (gPatched) return;
    Class lm = NSClassFromString(@"LicenseManager");
    if (lm) {
        Method m = class_getInstanceMethod(lm, sel_registerName("hasLicense"));
        if (m) method_setImplementation(m, (IMP)sw_hasLicense);

        m = class_getInstanceMethod(lm, sel_registerName("readLicenseInfo"));
        if (m) {
            gOrigReadLicenseInfo = method_getImplementation(m);
            method_setImplementation(m, (IMP)sw_readLicenseInfo);
        }
        m = class_getInstanceMethod(lm, sel_registerName("unfillLicense"));
        if (m) {
            gOrigUnfillLicense = method_getImplementation(m);
            method_setImplementation(m, (IMP)sw_unfillLicense);
        }
    }
    if (!gOrigEvaluateJS) {
        for (NSString *name in @[@"WKWebView", @"DocWebView"]) {
            Class wv = NSClassFromString(name);
            if (!wv) continue;
            Method m = class_getInstanceMethod(
                wv, sel_registerName("evaluateJavaScript:completionHandler:"));
            if (m) {
                gOrigEvaluateJS = method_getImplementation(m);
                method_setImplementation(m, (IMP)sw_evaluateJS);
                break;
            }
        }
    }
    gPatched = YES;
}

// 递归找 WebView 并补一次 JS 状态（仅 UI 兜底）
static void injectInto(id view, int depth) {
    if (!view || depth > 12) return;
    if ([view isKindOfClass:NSClassFromString(@"WKWebView")]) {
        NSString *js = @"(function(){try{"
                       @"window._options=window._options||{};"
                       @"window._options.hasLicense=true;"
                       @"if(window.File&&window.File.option){window.File.option.hasLicense=true;}"
                       @"}catch(e){}})();";
        ((void (*)(id, SEL, id, id))objc_msgSend)(
            view, sel_registerName("evaluateJavaScript:completionHandler:"), js, nil);
        return;
    }
    NSArray *subs = nil;
    @try { subs = ((id (*)(id, SEL))objc_msgSend)(view, sel_registerName("subviews")); }
    @catch (__unused NSException *e) { return; }
    for (id sub in subs) injectInto(sub, depth + 1);
}

// 让每个 TyWindowController 自己执行 onFillLicense（它会移除未激活角标）

static void callFillLicense(void) {
    Class lm = NSClassFromString(@"LicenseManager");
    if (lm) {
        id shared = ((id (*)(Class, SEL))objc_msgSend)(lm, sel_registerName("sharedInstance"));
        if (shared && [shared respondsToSelector:sel_registerName("postNotification")]) {
            ((void (*)(id, SEL))objc_msgSend)(shared, sel_registerName("postNotification"));
        }
    }
    for (NSWindow *w in [NSApplication sharedApplication].windows) {
        id wc = [w windowController];
        if (wc && [wc respondsToSelector:sel_registerName("onFillLicense")]) {
            ((void (*)(id, SEL))objc_msgSend)(wc, sel_registerName("onFillLicense"));
        }
    }
}

static void fixState(void) {
    Class lm = NSClassFromString(@"LicenseManager");
    if (lm) {
        id shared = ((id (*)(Class, SEL))objc_msgSend)(lm, sel_registerName("sharedInstance"));
        if (shared) {
            @try { [shared setValue:@YES forKey:@"hasLicense"]; } @catch (__unused NSException *e) {}
        }
    }
    for (NSWindow *w in [NSApplication sharedApplication].windows) {
        injectInto([w contentView], 0);
    }
    callFillLicense();
}

__attribute__((constructor)) static void bp_init(void) {
    installSwizzles();   // vm 加载时类已注册，先装 swizzle，抢在 start 之前生效

    [[NSNotificationCenter defaultCenter]
        addObserverForName:NSApplicationDidFinishLaunchingNotification
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(__unused NSNotification *n) {
                    installSwizzles();
                    fixState();
                }];

    // 少量重试覆盖 WebView 加载时序，不做 RunLoop 轮询
    const double delays[] = {0.5, 1.5, 3.0, 5.0, 8.0, 12.0};
    for (size_t i = 0; i < sizeof(delays) / sizeof(delays[0]); i++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)(delays[i] * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ fixState(); });
    }
}

