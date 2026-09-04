import api from './api.cjs'

export const compile = api.compile
export const compileSync = api.compileSync
export const compileFile = api.compileFile
export const compileFileSync = api.compileFileSync
export const detectSyntax = api.detectSyntax
export const ZigCssCompileError = api.ZigCssCompileError

export default Object.freeze({
  compile,
  compileSync,
  compileFile,
  compileFileSync,
  detectSyntax,
  ZigCssCompileError,
})
