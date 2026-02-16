import * as vscode from 'vscode';
import * as path from 'path';
import {
    LanguageClient,
    LanguageClientOptions,
    ServerOptions,
    TransportKind
} from 'vscode-languageclient/node';

let client: LanguageClient;

export function activate(context: vscode.ExtensionContext) {
    const config = vscode.workspace.getConfiguration('zigcss');
    const serverPath = config.get<string>('languageServerPath', 'zigcss');
    const serverArgs = config.get<string[]>('languageServerArgs', ['--lsp']);

    const serverOptions: ServerOptions = {
        run: {
            command: serverPath,
            args: serverArgs,
            transport: TransportKind.stdio
        },
        debug: {
            command: serverPath,
            args: serverArgs,
            transport: TransportKind.stdio
        }
    };

    const clientOptions: LanguageClientOptions = {
        documentSelector: [
            { scheme: 'file', language: 'css' },
            { scheme: 'file', language: 'scss' },
            { scheme: 'file', language: 'sass' },
            { scheme: 'file', language: 'less' },
            { scheme: 'file', language: 'stylus' }
        ],
        synchronize: {
            fileEvents: vscode.workspace.createFileSystemWatcher('**/*.{css,scss,sass,less,styl}')
        }
    };

    client = new LanguageClient(
        'zigcssLanguageServer',
        'zigcss Language Server',
        serverOptions,
        clientOptions
    );

    client.start();
}

export function deactivate(): Thenable<void> | undefined {
    if (!client) {
        return undefined;
    }
    return client.stop();
}
