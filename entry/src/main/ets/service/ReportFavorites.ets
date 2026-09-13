/** 精品收藏：报告 URL 本地收藏夹（preferences 持久化，按收藏时间倒序）。 */
import preferences from '@ohos.data.preferences';
import common from '@ohos.app.ability.common';

/** 单条收藏。 */
export interface ReportFavItem {
  /** 报告完整 URL。 */
  url: string
  /** 展示标题（优先页面 title，退化为文件名）。 */
  title: string
  /** 收藏时间戳（毫秒）。 */
  addedAt: number
}

/** preferences 文件名。 */
const PREFS_NAME: string = 'report_favs';
/** preferences 键名。 */
const KEY_ITEMS: string = 'items';

/** ReportFavorites：报告浏览器的收藏读写入口，全静态。 */
export class ReportFavorites {
  private static async open(ctx: common.Context): Promise<preferences.Preferences> {
    const options: preferences.Options = { name: PREFS_NAME };
    return await preferences.getPreferences(ctx, options);
  }

  private static async save(ctx: common.Context, items: ReportFavItem[]): Promise<void> {
    const prefs: preferences.Preferences = await ReportFavorites.open(ctx);
    prefs.putSync(KEY_ITEMS, JSON.stringify(items));
    await prefs.flush();
  }

  /** 读取全部收藏（坏数据逐条跳过，按 addedAt 倒序）。 */
  static async list(ctx: common.Context): Promise<ReportFavItem[]> {
    const prefs: preferences.Preferences = await ReportFavorites.open(ctx);
    const raw: string = prefs.getSync(KEY_ITEMS, '[]') as string;
    const parsed: ReportFavItem[] = JSON.parse(raw) as ReportFavItem[];
    const items: ReportFavItem[] = [];
    if (parsed === undefined || parsed === null) {
      return items;
    }
    for (let i: number = 0; i < parsed.length; i++) {
      const it: ReportFavItem | undefined = parsed[i];
      if (it === undefined || it === null || typeof it.url !== 'string' || it.url === '') {
        continue;
      }
      const item: ReportFavItem = {
        url: it.url,
        title: typeof it.title === 'string' ? it.title : '',
        addedAt: typeof it.addedAt === 'number' ? it.addedAt : 0,
      };
      items.push(item);
    }
    items.sort((a: ReportFavItem, b: ReportFavItem): number => b.addedAt - a.addedAt);
    return items;
  }

  /** 新增收藏；URL 已存在返回 false。 */
  static async add(ctx: common.Context, url: string, title: string): Promise<boolean> {
    const items: ReportFavItem[] = await ReportFavorites.list(ctx);
    for (let i: number = 0; i < items.length; i++) {
      if (items[i].url === url) {
        return false;
      }
    }
    const item: ReportFavItem = { url: url, title: title, addedAt: Date.now() };
    items.unshift(item);
    await ReportFavorites.save(ctx, items);
    return true;
  }

  /** 删除收藏；存在则删除返回 true。 */
  static async remove(ctx: common.Context, url: string): Promise<boolean> {
    const items: ReportFavItem[] = await ReportFavorites.list(ctx);
    const next: ReportFavItem[] = [];
    let found: boolean = false;
    for (let i: number = 0; i < items.length; i++) {
      if (items[i].url === url) {
        found = true;
        continue;
      }
      next.push(items[i]);
    }
    if (found) {
      await ReportFavorites.save(ctx, next);
    }
    return found;
  }

  /** 重命名收藏（url 定位，改写 title）。 */
  static async rename(ctx: common.Context, url: string, title: string): Promise<boolean> {
    const items: ReportFavItem[] = await ReportFavorites.list(ctx);
    let found: boolean = false;
    for (let i: number = 0; i < items.length; i++) {
      if (items[i].url === url) {
        items[i].title = title;
        found = true;
      }
    }
    if (found) {
      await ReportFavorites.save(ctx, items);
    }
    return found;
  }
}
