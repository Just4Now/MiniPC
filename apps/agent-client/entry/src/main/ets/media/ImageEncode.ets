/*
 * ImageEncode —— 聊天端把已选图片压成 inference v2 可承载的裸 base64。
 *
 * 与算力端 media/ImageAttach 的区别：
 *   - 输入是**聊天机沙盒内的本地文件路径**（ChatAttach 已落盘），不是相册 URI；
 *   - 输出是**裸 base64**（无 `data:` 前缀）：协议层的 image 字段只认 base64 字母表，
 *     且算力端 VlLlmTransport 对裸 base64 / dataUrl / 绝对路径三种形态都做了解析；
 *   - 上限 24000 必须与 packages/inference-protocol 的 LIMITS.maxImageBase64
 *     以及算力端 ChatProtocol.MAX_IMAGE_BASE64 三处一致。
 *
 * 约束链（已核对）：裸 base64 24000 + prompt 上限 32768 + 字段开销 ≈ 57 KB < MAX_FRAME 65536，
 * 因此带图时无需裁剪 prompt。
 */
import { image } from '@kit.ImageKit';
import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { MAX_IMAGE_BASE64 } from '../protocol/ChatProtocol';

const MAX_EDGE: number = 720;
const MIN_EDGE: number = 320;
const MIN_QUALITY: number = 40;

/**
 * 读取沙盒图片并自适应压成 ≤ MAX_IMAGE_BASE64 的裸 base64。
 * 逐级压缩：先降质量（70→40），再降边长（720→320），仍超限则报错。
 */
export async function encodeLocalImageBase64(path: string): Promise<string> {
  if (path.length === 0) {
    return '';
  }
  const file = await fileIo.open(path, fileIo.OpenMode.READ_ONLY);
  try {
    const source = image.createImageSource(file.fd);
    try {
      const info = await source.getImageInfo();
      if (info.size.width < 1 || info.size.height < 1) {
        throw new Error('图片无法识别');
      }
      let edge = MAX_EDGE;
      let quality = 70;
      for (;;) {
        let width = info.size.width;
        let height = info.size.height;
        const scale = Math.min(edge / width, edge / height);
        if (scale < 1) {
          width = Math.max(1, Math.round(width * scale));
          height = Math.max(1, Math.round(height * scale));
        }
        const decoding: image.DecodingOptions = { desiredSize: { width: width, height: height } };
        const pixelMap = await source.createPixelMap(decoding);
        let payload = '';
        try {
          const packer = image.createImagePacker();
          try {
            const packed = await packer.packToData(pixelMap, { format: 'image/jpeg', quality: quality });
            const encoded = new util.Base64Helper().encodeToStringSync(new Uint8Array(packed));
            if (encoded.length <= MAX_IMAGE_BASE64) {
              payload = encoded;
            }
          } finally {
            await packer.release();
          }
        } finally {
          await pixelMap.release();
        }
        if (payload.length > 0) {
          return payload;
        }
        if (quality > MIN_QUALITY) {
          quality -= 15;
        } else if (edge > MIN_EDGE) {
          edge = Math.max(MIN_EDGE, Math.round(edge * 0.75));
        } else {
          throw new Error('图片过大，压不进传输上限（请换一张更小的图片）');
        }
      }
    } finally {
      await source.release();
    }
  } finally {
    await fileIo.close(file);
  }
}
