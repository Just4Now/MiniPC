const fs=require('node:fs'),crypto=require('node:crypto');
const files=process.argv.slice(2);
if(!files.length){console.error('Usage: node cert-hash.cjs <certificate.pem> [...]');process.exit(2);}
for(const file of files){const text=fs.readFileSync(file,'utf8');for(const match of text.matchAll(/-----BEGIN CERTIFICATE-----([\s\S]*?)-----END CERTIFICATE-----/g)){const der=Buffer.from(match[1].replace(/\s/g,''),'base64');console.log(crypto.createHash('sha256').update(der).digest('hex'));}}
