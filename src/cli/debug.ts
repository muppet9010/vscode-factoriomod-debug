import * as os from "os";
import * as fsp from 'fs/promises';
import { program } from 'commander';

//@ts-ignore
import readdirGlob from 'readdir-glob';

import { URI, Utils } from 'vscode-uri';
import { ActiveFactorioVersion, FactorioVersion } from "../vscode/FactorioVersion";
import { fsAccessor, getConfigGetter } from "./util";


program.command("debug <factorioPath>")
	.description("Launch a DAP debug session")
	.option("-d, --docs <docsPath>", "path to runtime-api.json")
	.option("-c, --config <configPath>", "path to config.ini")
	.option("-w, --workspace <workspacePath...>", "path to workspace folders")
	.action(async (factorioPath:string, options:{docs?:string; config?:string; workspace?:string[]})=>{
		const fv: FactorioVersion = {
			name: "standalone",
			factorioPath: factorioPath,
			configPath: options.config,
			docsPath: options.docs,
		};
		const docsPath = Utils.joinPath(URI.file(factorioPath),
			fv.docsPath ? fv.docsPath :
			(os.platform() === "darwin") ? "../../doc-html/runtime-api.json" :
			"../../../doc-html/runtime-api.json"
		);
		const docsjson = await fsp.readFile(docsPath.fsPath, "utf8");
		const { ApiDocGenerator } = await import('../ApiDocs/ApiDocGenerator');
		const activeVersion = new ActiveFactorioVersion(fsAccessor, fv, new ApiDocGenerator(docsjson, await getConfigGetter("doc", {})));

		// start a single session that communicates via stdin/stdout
		const { FactorioModDebugSession } = await import('../Debug/factorioModDebug');
		const session = new FactorioModDebugSession(activeVersion, fsAccessor, {
			async findWorkspaceFiles(include) {
				const found:URI[] = [];
				for (const folder of options.workspace ?? [process.cwd()]) {
					const globber = readdirGlob(folder, {pattern: include});
					globber.on('match', (match:{ relative:string; absolute:string })=>{
						found.push(URI.file(match.absolute));
					});
					globber.on('error', (err:unknown)=>{
						throw err;
					});
					await new Promise<void>((resolve)=>{
						globber.on('end', ()=>{
							resolve();
						});
					});
				}
				return found;
			},
		});
		process.on('SIGTERM', ()=>{
			session.shutdown();
		});
		session.start(process.stdin, process.stdout);
	});