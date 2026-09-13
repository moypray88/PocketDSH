/** Markdown/消息图片的本地缓存：远端取图 → base64 落盘 → file:// URI 供 Image 组件渲染。 */
import fs from '@ohos.file.fs';
import fileUri from '@ohos.file.fileuri';
import util from '@ohos.util';
import common from '@ohos.app.ability.common';
import { BusinessError } from '@ohos.base';
import { DshSessionsRepository, ImageDataVm } from './DshSessionsRepository';

/** 取图失败（不支持的协议、服务端拒绝、落盘失败等）。 */
export class DshImageCacheError extends Error {
  readonly code: string;

  constructor(code: string, message: string) {
    super(message);
    this.code = code;
  }
}

/** 缓存目录名（app cache 下）。 */
const CACHE_DIR: string = 'mdimg';

/**
 * DshImageCache：
 * - https 外链：原样返回 URL（http 明文系统默认禁直连，不处理）；
 * - 服务器本地路径：session/readImage 取 base64 → cacheDir/mdimg/<hash>.<ext>；
 * - 消息内附件：session/attachment 取 base64 → cacheDir/mdimg/att-<hash>.<ext>。
 * 进程内 inflight 表去重并发请求；磁盘缓存跨页面/翻页复用。
 */
export class DshImageCache {
  private static inflight: Map<string, Promise<string>> = new Map();

  /** 解析 markdown 图片地址为可渲染源（https URL 或 file:// URI）。 */
  static async resolve(ctx: common.Context, src: string): Promise<string> {
    const s: string = src.trim();
    if (s === '') {
      throw new DshImageCacheError('empty', '图片地址为空');
    }
    if (s.indexOf('https://') === 0) {
      return s;
    }
    if (s.indexOf('http://') === 0) {
      throw new DshImageCacheError('http', '暂不支持明文 http 图片');
    }
    if (s.indexOf('data:') === 0) {
      return s;
    }
    let path: string = s;
    if (path.indexOf('file://') === 0) {
      path = path.substring('file://'.length);
    }
    if (path.indexOf('~') === 0) {
      throw new DshImageCacheError('home', '无法解析 ~ 开头的相对路径');
    }
    const key: string = 'md-' + DshImageCache.hash32(path);
    return DshImageCache.fetchIntoCache(ctx, key, path, (): Promise<ImageDataVm> => {
      return DshSessionsRepository.readImage(ctx, path);
    });
  }

  /** 解析消息内图片附件为可渲染源（file:// URI）。 */
  static async resolveAttachment(ctx: common.Context, sessionId: string, attachmentId: string): Promise<string> {
    const key: string = 'att-' + DshImageCache.hash32(sessionId + '|' + attachmentId);
    return DshImageCache.fetchIntoCache(ctx, key, '', (): Promise<ImageDataVm> => {
      return DshSessionsRepository.readAttachment(ctx, sessionId, attachmentId);
    });
  }

  /** 通用取图：查磁盘缓存 → 查 inflight → 远端取图落盘。 */
  private static async fetchIntoCache(ctx: common.Context, key: string, path: string,
    fetcher: () => Promise<ImageDataVm>): Promise<string> {
    const dir: string = ctx.cacheDir + '/' + CACHE_DIR;
    const cached: string = await DshImageCache.findCached(dir, key);
    if (cached !== '') {
      return cached;
    }
    const existing: Promise<string> | undefined = DshImageCache.inflight.get(key);
    if (existing !== undefined) {
      return existing;
    }
    const task: Promise<string> = DshImageCache.download(ctx, dir, key, fetcher);
    DshImageCache.inflight.set(key, task);
    try {
      return await task;
    } finally {
      DshImageCache.inflight.delete(key);
    }
  }

  /** 在缓存目录里找 key.* 任一扩展名的已有文件；找到返回 file:// URI。 */
  private static async findCached(dir: string, key: string): Promise<string> {
    const exts: string[] = ['.png', '.jpg', '.jpeg', '.webp', '.gif'];
    for (let i: number = 0; i < exts.length; i++) {
      const file: string = dir + '/' + key + exts[i];
      try {
        if (fs.accessSync(file)) {
          return fileUri.getUriFromPath(file);
        }
      } catch (_e) {
        // access 失败按未命中处理
      }
    }
    return '';
  }

  /** 远端取 base64 → 写缓存文件 → 返回 file:// URI。 */
  private static async download(ctx: common.Context, dir: string, key: string,
    fetcher: () => Promise<ImageDataVm>): Promise<string> {
    let img: ImageDataVm;
    try {
      img = await fetcher();
    } catch (err) {
      const e: BusinessError = err as BusinessError;
      throw new DshImageCacheError('fetch', e.message !== undefined ? e.message : '取图失败');
    }
    if (img.base64 === '') {
      throw new DshImageCacheError('empty-data', '服务端未返回图片内容');
    }
    const ext: string = DshImageCache.extOf(img.mediaType);
    const file: string = dir + '/' + key + ext;
    try {
      if (!fs.accessSync(dir)) {
        fs.mkdirSync(dir, true);
      }
      const bytes: Uint8Array = new util.Base64Helper().decodeSync(img.base64);
      const f: fs.File = fs.openSync(file, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      fs.writeSync(f.fd, bytes.buffer as ArrayBuffer);
      fs.closeSync(f.fd);
      return fileUri.getUriFromPath(file);
    } catch (err) {
      const e: BusinessError = err as BusinessError;
      throw new DshImageCacheError('io', '图片缓存写入失败：' + e.message);
    }
  }

  /** mediaType → 扩展名；未知类型默认 png。 */
  private static extOf(mediaType: string): string {
    if (mediaType === 'image/jpeg') {
      return '.jpg';
    }
    if (mediaType === 'image/webp') {
      return '.webp';
    }
    if (mediaType === 'image/gif') {
      return '.gif';
    }
    return '.png';
  }

  /** FNV-1a 32 位哈希（缓存文件名用，防长路径/特殊字符）。 */
  private static hash32(s: string): string {
    let h: number = 0x811c9dc5;
    for (let i: number = 0; i < s.length; i++) {
      h ^= s.charCodeAt(i) & 0xff;
      h = (h * 0x01000193) >>> 0;
      // 高位字节单独混合（charCode 可能 > 255，中文路径）
      const c: number = s.charCodeAt(i) >> 8;
      if (c > 0) {
        h ^= c;
        h = (h * 0x01000193) >>> 0;
      }
    }
    return h.toString(16);
  }
}
