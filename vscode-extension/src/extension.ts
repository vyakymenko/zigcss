import * as vscode from 'vscode';
import {
    LanguageClient,
    LanguageClientOptions,
    ServerOptions,
    TransportKind
} from 'vscode-languageclient/node';
import { discoverServer } from './binaryDiscovery';

let client: LanguageClient | undefined;

export async function activate(context: vscode.ExtensionContext): Promise<void> {
    const config = vscode.workspace.getConfiguration('zigcss');
    const configuredPath = config.get<unknown>('languageServerPath');
    if (configuredPath !== undefined && typeof configuredPath !== 'string') {
        await vscode.window.showErrorMessage(
            'zigcss.languageServerPath must be a string.',
        );
        return;
    }
    const discovery = discoverServer(
        configuredPath,
        {
            extensionPath: context.extensionPath,
            platform: process.platform,
            env: process.env,
        },
    );
    if (!discovery.ok) {
        await vscode.window.showErrorMessage(discovery.message);
        return;
    }

    const configuredArgs = config.get<unknown>('languageServerArgs', ['--lsp']);
    if (!Array.isArray(configuredArgs) ||
        configuredArgs.length > 16 ||
        !configuredArgs.every(argument =>
            typeof argument === 'string' &&
            argument.length <= 4096 &&
            !argument.includes('\0')))
    {
        await vscode.window.showErrorMessage(
            'zigcss.languageServerArgs must contain at most 16 NUL-free strings of at most 4096 characters.',
        );
        return;
    }
    const serverArgs = configuredArgs as string[];

    const serverOptions: ServerOptions = {
        run: {
            command: discovery.command,
            args: serverArgs,
            transport: TransportKind.stdio
        },
        debug: {
            command: discovery.command,
            args: serverArgs,
            transport: TransportKind.stdio
        }
    };

    const clientOptions: LanguageClientOptions = {
        documentSelector: [
            { scheme: 'file', language: 'css' }
        ]
    };

    client = new LanguageClient(
        'zigcssLanguageServer',
        'zigcss Language Server',
        serverOptions,
        clientOptions
    );

    context.subscriptions.push(client);
    await client.start();
}

export function deactivate(): Thenable<void> | undefined {
    if (client === undefined) {
        return undefined;
    }
    return client.stop();
}
