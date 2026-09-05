/** 服务器健康探针：Basic Auth 探测根地址，产出连接中心状态卡所需的快照。 */
import http from '@ohos.net.http';
import util from '@ohos.util';
import { BusinessError } from '@ohos.base';
import { HealthSnapshot } from '../model/DshTypes';

/** 连接 / 读取超时（毫秒）。 */
const PROBE_TIMEOUT_MS: number = 8000;

/**
 * HealthMonitor：对服务器根地址发起一次带 Basic Auth 的 GET 请求。
 * 任意 HTTP 响应即视为在线（online=true），
 * 200 -> 'ok'，401 -> 'auth-required'，其余 -> 'http-<code>'；
 * 网络异常时 online=false、latencyMs=-1、detail 为错误信息。
 */
export class HealthMonitor {
  static async probe(serverUrl: string, username: string, password: string): Promise<HealthSnapshot> {
    const req: http.HttpRequest = http.createHttp();
    // Basic Auth 凭据：base64(user:pass)，字节转换用 TextEncoder
    const encoder: util.TextEncoder = new util.TextEncoder();
    const credentials: string = username + ':' + password;
    const token: string = new util.Base64Helper().encodeToStringSync(encoder.encodeInto(credentials));
    const header: Record<string, string> = {
      'Authorization': 'Basic ' + token
    };
    const options: http.HttpRequestOptions = {
      method: http.RequestMethod.GET,
      header: header,
      usingCache: false,
      connectTimeout: PROBE_TIMEOUT_MS,
      readTimeout: PROBE_TIMEOUT_MS,
      expectDataType: http.HttpDataType.STRING
    };
    const startedAt: number = Date.now();
    try {
      const resp: http.HttpResponse = await req.request(serverUrl, options);
      const latencyMs: number = Date.now() - startedAt;
      const code: number = resp.responseCode;
      let detail: string = 'http-' + code;
      if (code === 200) {
        detail = 'ok';
      } else if (code === 401) {
        detail = 'auth-required';
      }
      const snapshot: HealthSnapshot = {
        online: true,
        latencyMs: latencyMs,
        checkedAt: Date.now(),
        detail: detail
      };
      return snapshot;
    } catch (err) {
      const e: BusinessError = err as BusinessError;
      let detail: string = e.message;
      if (detail === '') {
        detail = 'error-' + e.code;
      }
      const snapshot: HealthSnapshot = {
        online: false,
        latencyMs: -1,
        checkedAt: Date.now(),
        detail: detail
      };
      return snapshot;
    } finally {
      // 释放底层连接资源
      req.destroy();
    }
  }
}
