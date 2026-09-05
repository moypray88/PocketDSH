/** PocketDSH 双主题令牌系统：深空指挥舱（深）/ 极简商务白（浅）。设置页可切换。 */

export interface ThemeColors {
  /** 页面渐变起点/终点。 */
  bgGradStart: string
  bgGradEnd: string
  /** 卡片背景（含透明度的玻璃拟态）与导航栏背景。 */
  bgCard: string
  bgRail: string
  border: string
  textPrimary: string
  textSecondary: string
  textTertiary: string
  accent: string
  accent2: string
  /** 强调按钮上的文字颜色。 */
  onAccent: string
  success: string
  warn: string
  danger: string
  termBg: string
  termText: string
  /** 导航选中项背景。 */
  navActiveBg: string
  shadow: string
}

export class ThemeManager {
  static readonly DARK: ThemeColors = {
    bgGradStart: '#06090F',
    bgGradEnd: '#150F30',
    bgCard: 'rgba(255,255,255,0.06)',
    bgRail: 'rgba(10,14,28,0.72)',
    border: 'rgba(255,255,255,0.12)',
    textPrimary: '#ECF0FB',
    textSecondary: '#97A1C0',
    textTertiary: '#6C7799',
    accent: '#22D3EE',
    accent2: '#8B5CF6',
    onAccent: '#04121C',
    success: '#34D399',
    warn: '#FBBF24',
    danger: '#F87171',
    termBg: '#05070D',
    termText: '#A8E6F3',
    navActiveBg: 'rgba(34,211,238,0.16)',
    shadow: 'rgba(0,0,0,0.45)',
  }

  static readonly LIGHT: ThemeColors = {
    bgGradStart: '#F4F6FA',
    bgGradEnd: '#E9EDF5',
    bgCard: '#FFFFFF',
    bgRail: '#FFFFFF',
    border: '#E7EBF2',
    textPrimary: '#0F172A',
    textSecondary: '#5B6B85',
    textTertiary: '#93A1B8',
    accent: '#2563EB',
    accent2: '#1E3A8A',
    onAccent: '#FFFFFF',
    success: '#0E9F6E',
    warn: '#B45309',
    danger: '#DC2626',
    termBg: '#0F1B2D',
    termText: '#C9E3F5',
    navActiveBg: '#EDF3FF',
    shadow: 'rgba(15,23,42,0.08)',
  }

  static palette(dark: boolean): ThemeColors {
    return dark ? ThemeManager.DARK : ThemeManager.LIGHT
  }

  /**
   * 应用主题模式：写入 AppStorage 的 themeIsDark。
   * @param mode 0 跟随系统 / 1 深色 / 2 浅色
   * @param systemDark 当前系统是否深色（由 EntryAbility 探测传入）
   */
  static apply(mode: number, systemDark: boolean): void {
    let dark = true
    if (mode === 1) {
      dark = true
    } else if (mode === 2) {
      dark = false
    } else {
      dark = systemDark
    }
    AppStorage.setOrCreate('themeIsDark', dark)
  }
}
