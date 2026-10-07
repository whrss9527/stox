/// 菜单栏隐藏文字的判断不依赖 AppKit；没有证券市场时不自动隐藏。
public enum TickerVisibility {
    public static func isHidden(manuallyHidden: Bool, hideWhenClosed: Bool, hasRegions: Bool, marketsLive: Bool) -> Bool {
        manuallyHidden || (hideWhenClosed && hasRegions && !marketsLive)
    }
}
