project(
  'zigcss_depfile_example',
  meson_version: '>=0.47.0',
)

zigcss = find_program(get_option('zigcss'))

custom_target(
  'styles',
  input: 'styles.scss',
  output: 'styles.css',
  command: [
    zigcss, '@INPUT@',
    '--syntax', 'scss',
    '--minify',
    '-o', '@OUTPUT@',
    '--depfile', '@DEPFILE@',
  ],
  depfile: 'styles.css.d',
  build_by_default: true,
)
