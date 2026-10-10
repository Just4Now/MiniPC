const fs=require('node:fs');
const [source,output]=process.argv.slice(2);
if(!source||!output){console.error('Usage: node clean-release-profile.cjs <source-profile.json> <output.json>');process.exit(2);}
const value=JSON.parse(fs.readFileSync(source,'utf8'));
const match=String(value['bundle-info']['distribution-certificate']).match(/-----BEGIN CERTIFICATE-----([\s\S]*?)-----END CERTIFICATE-----/);
if(!match)throw Error('Missing certificate');
const lines=match[1].replace(/\s/g,'').match(/.{1,64}/g);
value['bundle-info']['distribution-certificate']='-----BEGIN CERTIFICATE-----\n'+lines.join('\n')+'\n-----END CERTIFICATE-----\n';
fs.writeFileSync(output,JSON.stringify(value)+'\n');
