import {readdir,readFile,writeFile} from 'node:fs/promises';
import {join,relative} from 'node:path';
import {createHash} from 'node:crypto';
const [root,revision,nodeVersion]=process.argv.slice(2);
if(!root||!/^[0-9a-f]{40}$/.test(revision||''))throw Error('INVALID_BUILD_MANIFEST_INPUT');
const Files=[];
async function visit(path){for(const item of await readdir(path,{withFileTypes:true})){const file=join(path,item.name);if(item.isDirectory())await visit(file);else if(item.isFile()&&file!==join(root,'build-manifest.json'))Files.push({File:relative(root,file),Sha256:createHash('sha256').update(await readFile(file)).digest('hex').toUpperCase()});}}
await visit(root);
const SchoolIds=(await readdir(join(root,'adapters'))).filter(x=>x.endsWith('.json')).map(x=>x.slice(0,-5)).sort();
await writeFile(join(root,'build-manifest.json'),JSON.stringify({BuildTime:new Date().toISOString(),SourceCommit:revision,Trial:true,SchoolIds,RealCampusVerified:false,NodeVersion:nodeVersion,Files},null,2));
console.log('Manifest runtime files: '+Files.length);
