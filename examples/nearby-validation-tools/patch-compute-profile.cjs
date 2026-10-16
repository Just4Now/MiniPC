const fs=require('node:fs');
const [certificate,source,output]=process.argv.slice(2);
if(!certificate||!source||!output){console.error('Usage: node patch-compute-profile.cjs <certificate.pem> <source-profile.json> <output.json>');process.exit(2);}
const value=JSON.parse(fs.readFileSync(source,'utf8'));
value['bundle-info']['development-certificate']=fs.readFileSync(certificate,'utf8').trim()+'\n';
fs.writeFileSync(output,JSON.stringify(value,null,2)+'\n');
