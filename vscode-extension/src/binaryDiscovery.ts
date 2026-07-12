import * as fs from 'fs';
import * as path from 'path';

export type DiscoverySource =
    | 'configured-path'
    | 'configured-command'
    | 'bundled'
    | 'path';

export type DiscoveryResult =
    | {
        ok: true;
        command: string;
        source: DiscoverySource;
        checked: string[];
    }
    | {
        ok: false;
        message: string;
        checked: string[];
    };

export interface DiscoveryOptions {
    extensionPath: string;
    platform?: NodeJS.Platform;
    env?: NodeJS.ProcessEnv;
    isUsableFile?: (candidate: string) => boolean;
}

const maxConfiguredPathLength = 65536;

function environmentValue(
    env: NodeJS.ProcessEnv,
    name: string,
    platform: NodeJS.Platform,
): string | undefined {
    if (platform !== 'win32') return env[name];
    const key = Object.keys(env).find(candidate =>
        candidate.toUpperCase() === name.toUpperCase());
    return key === undefined ? undefined : env[key];
}

function executableNames(
    command: string,
    platform: NodeJS.Platform,
    env: NodeJS.ProcessEnv,
): string[] {
    if (platform !== 'win32' || path.win32.extname(command) !== '') {
        return [command];
    }
    const rawExtensions = environmentValue(env, 'PATHEXT', platform) ??
        '.COM;.EXE;.BAT;.CMD';
    const parsedExtensions = rawExtensions
        .split(';')
        .map(extension => extension.trim())
        .filter(extension => extension.startsWith('.') && extension.length > 1);
    const extensions = parsedExtensions.length === 0
        ? ['.COM', '.EXE', '.BAT', '.CMD']
        : parsedExtensions;
    return [...new Set(extensions.map(extension => `${command}${extension}`))];
}

function defaultUsableFile(
    candidate: string,
    platform: NodeJS.Platform,
): boolean {
    try {
        if (!fs.statSync(candidate).isFile()) return false;
        if (platform !== 'win32') fs.accessSync(candidate, fs.constants.X_OK);
        return true;
    } catch {
        return false;
    }
}

export function discoverServer(
    configuredPath: string | undefined,
    options: DiscoveryOptions,
): DiscoveryResult {
    const platform = options.platform ?? process.platform;
    const env = options.env ?? process.env;
    const paths = platform === 'win32' ? path.win32 : path.posix;
    const isUsable = options.isUsableFile ??
        ((candidate: string) => defaultUsableFile(candidate, platform));
    const checked: string[] = [];
    const checkedSet = new Set<string>();

    const check = (candidate: string): boolean => {
        if (!checkedSet.has(candidate)) {
            checkedSet.add(candidate);
            checked.push(candidate);
        }
        return isUsable(candidate);
    };

    const searchPath = (command: string): string | undefined => {
        const rawPath = environmentValue(env, 'PATH', platform) ?? '';
        const names = executableNames(command, platform, env);
        for (const rawDirectory of rawPath.split(paths.delimiter).slice(0, 1024)) {
            const directory = rawDirectory.trim().replace(/^"(.*)"$/, '$1');
            if (directory.length === 0 || !paths.isAbsolute(directory)) continue;
            for (const name of names) {
                const candidate = paths.join(directory, name);
                if (check(candidate)) return candidate;
            }
        }
        return undefined;
    };

    if (configuredPath !== undefined &&
        (configuredPath.length > maxConfiguredPathLength ||
            configuredPath.includes('\0')))
    {
        return {
            ok: false,
            message: 'zigcss.languageServerPath exceeds its limits or contains NUL.',
            checked,
        };
    }

    const configured = configuredPath?.trim() ?? '';
    if (configured.length > 0) {
        if (paths.isAbsolute(configured)) {
            const candidate = paths.normalize(configured);
            if (check(candidate)) {
                return {
                    ok: true,
                    command: candidate,
                    source: 'configured-path',
                    checked,
                };
            }
            return {
                ok: false,
                message: `The configured executable does not exist or is not executable: ${candidate}`,
                checked,
            };
        }
        if (configured.includes('/') || configured.includes('\\')) {
            return {
                ok: false,
                message: 'zigcss.languageServerPath must be an absolute path or a bare command name.',
                checked,
            };
        }
        const command = searchPath(configured);
        if (command !== undefined) {
            return {
                ok: true,
                command,
                source: 'configured-command',
                checked,
            };
        }
        return {
            ok: false,
            message: `The configured command '${configured}' was not found in an absolute PATH directory.`,
            checked,
        };
    }

    if (paths.isAbsolute(options.extensionPath)) {
        const bundledName = platform === 'win32' ? 'zigcss.exe' : 'zigcss';
        const bundled = paths.join(options.extensionPath, 'bin', bundledName);
        if (check(bundled)) {
            return {
                ok: true,
                command: bundled,
                source: 'bundled',
                checked,
            };
        }
    }

    const command = searchPath('zigcss');
    if (command !== undefined) {
        return {
            ok: true,
            command,
            source: 'path',
            checked,
        };
    }
    return {
        ok: false,
        message: 'No ZigCSS language server was found in the extension package and absolute PATH entries. Set zigcss.languageServerPath to an absolute executable path or bare command name.',
        checked,
    };
}
