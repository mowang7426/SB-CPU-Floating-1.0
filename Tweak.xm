static __attribute__((unused)) NSDictionary *SBCPUConfig(void) {
    NSString *p = @"/var/mobile/Library/Preferences/com.sbcpufloating.monitor.plist";
    return [NSDictionary dictionaryWithContentsOfFile:p] ?: @{};
}

static __attribute__((unused)) double SBCPUThresholdValue(void) {
    NSNumber *n = SBCPUConfig()[@"CPUThreshold"];
    return n ? n.doubleValue : 85.0;
}

static __attribute__((unused)) double SBCPUHoldTimeValue(void) {
    NSNumber *n = SBCPUConfig()[@"HoldTime"];
    return n ? n.doubleValue : 10.0;
}

static __attribute__((unused)) BOOL SBCAutoRespringValue(void) {
    NSNumber *n = SBCPUConfig()[@"AutoRespring"];
    return n ? n.boolValue : NO;
}
