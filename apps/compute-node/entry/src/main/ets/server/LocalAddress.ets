import { connection } from '@kit.NetworkKit';

/**
 * 本机 LAN IPv4（面板展示接入地址用）。
 * 走默认网络（WiFi/以太网）；GET_NETWORK_INFO 权限已在 module.json5 声明。
 * 取不到（无网络/接口形状变化）返回空串，由上层降级展示。
 */
export async function localIpv4(): Promise<string> {
  try {
    const net = await connection.getDefaultNet();
    const properties = await connection.getConnectionProperties(net);
    const links = properties.linkAddresses;
    if (!Array.isArray(links)) return '';
    for (const link of links) {
      const address = link?.address?.address || '';
      if (address.length === 0 || address.indexOf(':') >= 0) continue;
      if (address.indexOf('.') < 0) continue;
      if (address.indexOf('127.') === 0) continue;
      return address;
    }
  } catch (_error) {
    // 无默认网络或权限异常：留给上层降级。
  }
  return '';
}
