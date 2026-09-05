/** 基于系统资产库（@ohos.security.asset）的密钥字符串加密存取层。 */
import asset from '@ohos.security.asset';
import util from '@ohos.util';

/** 资产库别名：nginx Basic Auth 密码。 */
export const SECURE_ALIAS_PASSWORD: string = 'dsh_basic_password';

/** 资产库别名：dsh 令牌 URL（含 token 参数的完整地址）。 */
export const SECURE_ALIAS_TOKEN: string = 'dsh_web_token_url';

/**
 * SecureStore：敏感信息（密码 / 令牌 URL）写入系统资产库，由系统加密保护。
 * 读不到或发生任何异常时一律返回空字符串，调用方无需处理资产库错误细节。
 */
export class SecureStore {
  /** 字符串转字节（资产库仅接受 Uint8Array 形式的别名与密文）。 */
  private static toBytes(text: string): Uint8Array {
    const encoder: util.TextEncoder = new util.TextEncoder();
    return encoder.encodeInto(text);
  }

  /** 字节转字符串（资产库读出的密文是 UTF-8 字节）。 */
  private static toText(bytes: Uint8Array): string {
    const decoder: util.TextDecoder = util.TextDecoder.create('utf-8');
    return decoder.decodeWithStream(bytes);
  }

  /** 构造仅含别名的 AssetMap，供 remove / query 作为查询条件使用。 */
  private static aliasMap(alias: string): asset.AssetMap {
    const map: asset.AssetMap = new Map();
    map.set(asset.Tag.ALIAS, SecureStore.toBytes(alias));
    return map;
  }

  /**
   * 保存密钥：若同名资产已存在则先删除再写入，避免 add 别名冲突。
   */
  static async saveSecret(alias: string, value: string): Promise<void> {
    // 资产不存在时 remove 会抛错，deleteSecret 内部已吞掉，可安全调用
    await SecureStore.deleteSecret(alias);
    const map: asset.AssetMap = SecureStore.aliasMap(alias);
    map.set(asset.Tag.SECRET, SecureStore.toBytes(value));
    map.set(asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_FIRST_UNLOCKED);
    await asset.add(map);
  }

  /**
   * 读取密钥：不存在或发生任何异常（内部 catch）时返回空字符串。
   */
  static async readSecret(alias: string): Promise<string> {
    try {
      const query: asset.AssetMap = SecureStore.aliasMap(alias);
      query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL);
      const result: Array<asset.AssetMap> = await asset.query(query);
      if (result.length === 0) {
        return '';
      }
      const secret: Uint8Array = result[0].get(asset.Tag.SECRET) as Uint8Array;
      return SecureStore.toText(secret);
    } catch (err) {
      // 别名不存在、锁屏状态等一切异常统一降级为空串
      return '';
    }
  }

  /**
   * 删除密钥：资产不存在或删除失败时静默忽略。
   */
  static async deleteSecret(alias: string): Promise<void> {
    try {
      await asset.remove(SecureStore.aliasMap(alias));
    } catch (err) {
      // 吞掉异常：调用方只关心"删除后不再存在"这一结果
    }
  }
}
