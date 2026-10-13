import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { image } from '@kit.ImageKit';
import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { MAX_IMAGE_BASE64 } from '../protocol/ChatProtocol';

const MAX_EDGE: number = 720;
const MIN_EDGE: number = 320;
const MIN_QUALITY: number = 40;
const JPEG_DATAURL_PREFIX: string = 'data:image/jpeg;base64,';

/** 传输用裸 base64：剥掉 data: 前缀，协议校验只认 base64 字符。 */
export function jpegBase64Payload(dataUrl: string): string {
  return dataUrl.indexOf(JPEG_DATAURL_PREFIX) === 0 ? dataUrl.slice(JPEG_DATAURL_PREFIX.length) : dataUrl;
}

export function pickJpegDataUrl(): Promise<string> {
  const picker = new photoAccessHelper.PhotoViewPicker();
  const options = new photoAccessHelper.PhotoSelectOptions();
  options.MIMEType = photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE;
  options.maxSelectNumber = 1;
  return picker.select(options).then((result: photoAccessHelper.PhotoSelectResult) => {
    if (result.photoUris.length === 0) {
      return Promise.resolve('');
    }
    return encodeJpegDataUrl(result.photoUris[0]);
  }).catch((error: BusinessError) => {
    if (isCancel(error)) {
      return '';
    }
    hilog.error(0, 'ImageAttach', 'select failed code=%{public}d msg=%{public}s', error.code, error.message);
    return Promise.reject(error);
  });
}

function isCancel(error: BusinessError): boolean {
  if (error.code === 13900020 || error.code === 13900002 || error.code === 801) {
    return true;
  }
  const msg = error.message ? error.message.toLowerCase() : '';
  return msg.indexOf('cancel') >= 0;
}

async function encodeJpegDataUrl(uri: string): Promise<string> {
  const file = await fileIo.open(uri, fileIo.OpenMode.READ_ONLY);
  try {
    const source = image.createImageSource(file.fd);
    try {
      const info = await source.getImageInfo();
      if (info.size.width < 1 || info.size.height < 1) {
        throw new Error('invalid image');
      }
      // 图片要随请求走近场链路：先按最大边长和质量打包，超预算就逐级压缩，
      // 直到落进协议的 base64 上限（多模态输入本身也会被模型缩放，小图够用）。
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
        let dataUrl = '';
        try {
          const packer = image.createImagePacker();
          try {
            const packed = await packer.packToData(pixelMap, { format: 'image/jpeg', quality: quality });
            const base64 = new util.Base64Helper().encodeToStringSync(new Uint8Array(packed));
            if (base64.length <= MAX_IMAGE_BASE64) dataUrl = JPEG_DATAURL_PREFIX + base64;
          } finally {
            await packer.release();
          }
        } finally {
          await pixelMap.release();
        }
        if (dataUrl.length > 0) return dataUrl;
        if (quality > MIN_QUALITY) quality -= 15;
        else if (edge > MIN_EDGE) edge = Math.max(MIN_EDGE, Math.round(edge * 0.75));
        else throw new Error('image too large');
      }
    } finally {
      await source.release();
    }
  } finally {
    await fileIo.close(file);
  }
}
