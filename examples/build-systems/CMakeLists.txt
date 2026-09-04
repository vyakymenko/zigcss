cmake_minimum_required(VERSION 3.20)
project(zigcss_depfile_example LANGUAGES NONE)

set(ZIGCSS "zigcss" CACHE FILEPATH "Path to the ZigCSS executable")
set(INPUT "${CMAKE_CURRENT_SOURCE_DIR}/styles.scss")
set(OUTPUT "${CMAKE_CURRENT_BINARY_DIR}/styles.css")
set(DEPFILE "${CMAKE_CURRENT_BINARY_DIR}/styles.css.d")

add_custom_command(
  OUTPUT "${OUTPUT}"
  COMMAND "${ZIGCSS}" "${INPUT}"
          --syntax scss --minify
          -o "${OUTPUT}" --depfile "${DEPFILE}"
  DEPENDS "${INPUT}"
  DEPFILE "${DEPFILE}"
  VERBATIM
)

add_custom_target(styles ALL DEPENDS "${OUTPUT}")
