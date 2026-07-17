# ZigCSS npm runtime third-party notices

This inventory covers the exact locked runtime graph used by the canonical SCSS, indented Sass, Less, and Stylus host. Each installed npm dependency retains its own license file and package metadata.

## Reviewed compatibility exception

Stylus 0.64.0 declares `glob ^10.4.5`. ZigCSS locks `glob 10.5.0`: the fixed 10.x release for GHSA-5j98-mcp5-4vw2. The registry retains a generic old-major deprecation notice, so this exact exception is fail-closed in the package gate. ZigCSS invokes only the bounded library iterator; the glob CLI is never called or exposed.

| Locked package path | Version | SPDX license | npm integrity |
| --- | --- | --- | --- |
| `node_modules/@adobe/css-tools` | `4.3.3` | `MIT` | `sha512-rE0Pygv0sEZ4vBWHlAgJLGDU7Pm8xoO6p3wsEceb7GYAjScrOHpEo8KK/eVkAcnSM+slAEtXjA2JpdjLp4fJQQ==` |
| `node_modules/@isaacs/cliui` | `8.0.2` | `ISC` | `sha512-O8jcjabXaleOG9DQ0+ARXWZBTfnP4WNAqzuiJK7ll44AmxGKv/J2M4TPjxjY3znBCfvBXFzucm1twdyFybFqEA==` |
| `node_modules/@parcel/watcher` | `2.5.6` | `MIT` | `sha512-tmmZ3lQxAe/k/+rNnXQRawJ4NjxO2hqiOLTHvWchtGZULp4RyFeh6aU4XdOYBFe2KE1oShQTv4AblOs2iOrNnQ==` |
| `node_modules/@parcel/watcher-android-arm64` | `2.5.6` | `MIT` | `sha512-YQxSS34tPF/6ZG7r/Ih9xy+kP/WwediEUsqmtf0cuCV5TPPKw/PQHRhueUo6JdeFJaqV3pyjm0GdYjZotbRt/A==` |
| `node_modules/@parcel/watcher-darwin-arm64` | `2.5.6` | `MIT` | `sha512-Z2ZdrnwyXvvvdtRHLmM4knydIdU9adO3D4n/0cVipF3rRiwP+3/sfzpAwA/qKFL6i1ModaabkU7IbpeMBgiVEA==` |
| `node_modules/@parcel/watcher-darwin-x64` | `2.5.6` | `MIT` | `sha512-HgvOf3W9dhithcwOWX9uDZyn1lW9R+7tPZ4sug+NGrGIo4Rk1hAXLEbcH1TQSqxts0NYXXlOWqVpvS1SFS4fRg==` |
| `node_modules/@parcel/watcher-freebsd-x64` | `2.5.6` | `MIT` | `sha512-vJVi8yd/qzJxEKHkeemh7w3YAn6RJCtYlE4HPMoVnCpIXEzSrxErBW5SJBgKLbXU3WdIpkjBTeUNtyBVn8TRng==` |
| `node_modules/@parcel/watcher-linux-arm-glibc` | `2.5.6` | `MIT` | `sha512-9JiYfB6h6BgV50CCfasfLf/uvOcJskMSwcdH1PHH9rvS1IrNy8zad6IUVPVUfmXr+u+Km9IxcfMLzgdOudz9EQ==` |
| `node_modules/@parcel/watcher-linux-arm-musl` | `2.5.6` | `MIT` | `sha512-Ve3gUCG57nuUUSyjBq/MAM0CzArtuIOxsBdQ+ftz6ho8n7s1i9E1Nmk/xmP323r2YL0SONs1EuwqBp2u1k5fxg==` |
| `node_modules/@parcel/watcher-linux-arm64-glibc` | `2.5.6` | `MIT` | `sha512-f2g/DT3NhGPdBmMWYoxixqYr3v/UXcmLOYy16Bx0TM20Tchduwr4EaCbmxh1321TABqPGDpS8D/ggOTaljijOA==` |
| `node_modules/@parcel/watcher-linux-arm64-musl` | `2.5.6` | `MIT` | `sha512-qb6naMDGlbCwdhLj6hgoVKJl2odL34z2sqkC7Z6kzir8b5W65WYDpLB6R06KabvZdgoHI/zxke4b3zR0wAbDTA==` |
| `node_modules/@parcel/watcher-linux-x64-glibc` | `2.5.6` | `MIT` | `sha512-kbT5wvNQlx7NaGjzPFu8nVIW1rWqV780O7ZtkjuWaPUgpv2NMFpjYERVi0UYj1msZNyCzGlaCWEtzc+exjMGbQ==` |
| `node_modules/@parcel/watcher-linux-x64-musl` | `2.5.6` | `MIT` | `sha512-1JRFeC+h7RdXwldHzTsmdtYR/Ku8SylLgTU/reMuqdVD7CtLwf0VR1FqeprZ0eHQkO0vqsbvFLXUmYm/uNKJBg==` |
| `node_modules/@parcel/watcher-win32-arm64` | `2.5.6` | `MIT` | `sha512-3ukyebjc6eGlw9yRt678DxVF7rjXatWiHvTXqphZLvo7aC5NdEgFufVwjFfY51ijYEWpXbqF5jtrK275z52D4Q==` |
| `node_modules/@parcel/watcher-win32-ia32` | `2.5.6` | `MIT` | `sha512-k35yLp1ZMwwee3Ez/pxBi5cf4AoBKYXj00CZ80jUz5h8prpiaQsiRPKQMxoLstNuqe2vR4RNPEAEcjEFzhEz/g==` |
| `node_modules/@parcel/watcher-win32-x64` | `2.5.6` | `MIT` | `sha512-hbQlYcCq5dlAX9Qx+kFb0FHue6vbjlf0FrNzSKdYK2APUf7tGfGxQCk2ihEREmbR6ZMc0MVAD5RIX/41gpUzTw==` |
| `node_modules/@pkgjs/parseargs` | `0.11.0` | `MIT` | `sha512-+1VkjdD0QBLPodGrJUeqarH8VAIvQODIbwh9XpP5Syisf7YoQgsJKPNFoqqLQlu+VQ/tVSshMR6loPMn8U+dPg==` |
| `node_modules/ansi-regex` | `6.2.2` | `MIT` | `sha512-Bq3SmSpyFHaWjPk8If9yc6svM8c56dB5BAtW4Qbw5jHTwwXXcTLoRMkpDJp6VL0XzlWaCHTXrkFURMYmD0sLqg==` |
| `node_modules/ansi-styles` | `6.2.3` | `MIT` | `sha512-4Dj6M28JB+oAH8kFkTLUo+a2jwOFkuqb3yucU0CANcRRUbxS0cP0nZYCGjcc3BNXwRIsUVmDGgzawme7zvJHvg==` |
| `node_modules/balanced-match` | `1.0.2` | `MIT` | `sha512-3oSeUO0TMV67hN1AmbXsK4yaqU7tjiHlbxRDZOpH0KW9+CeX4bRAaX0Anxt0tx2MrpRpWwQaPwIlISEJhYU5Pw==` |
| `node_modules/brace-expansion` | `2.1.2` | `MIT` | `sha512-w5JZcKgdhDOgOwm8H+KgbosopHMuGcl6qbulwjtz3SM7I7P3yW1eAjzMPLrIE+NQ9vjgANKHWeMHnrT0OXW1oA==` |
| `node_modules/chokidar` | `5.0.0` | `MIT` | `sha512-TQMmc3w+5AxjpL8iIiwebF73dRDF4fBIieAqGn9RGCWaEVwQ6Fb2cGe31Yns0RRIzii5goJ1Y7xbMwo1TxMplw==` |
| `node_modules/color-convert` | `2.0.1` | `MIT` | `sha512-RRECPsj7iu/xb5oKYcsFHSppFNnsj/52OVTRKb4zP5onXwVF3zVmmToNcOfGC+CRDpfK/U584fMg38ZHCaElKQ==` |
| `node_modules/color-name` | `1.1.4` | `MIT` | `sha512-dOy+3AuW3a2wNbZHIuMZpTcgjGuLU/uBL/ubcZF9OXbDo8ff4O8yVp5Bf0efS8uEoYo5q4Fx7dY9OgQGXgAsQA==` |
| `node_modules/copy-anything` | `3.0.5` | `MIT` | `sha512-yCEafptTtb4bk7GLEQoM8KVJpxAfdBJYaXyzQEgQQQgYrZiDp8SJmGKlYza6CYjEDNstAdNdKA3UuoULlEbS6w==` |
| `node_modules/cross-spawn` | `7.0.6` | `MIT` | `sha512-uV2QOWP2nWzsy2aMp8aRibhi9dlzF5Hgh5SHaB9OiTGEyDTiJJyx0uy51QXdyWbtAHNua4XJzUKca3OzKUd3vA==` |
| `node_modules/debug` | `4.4.3` | `MIT` | `sha512-RGwwWnwQvkVfavKVt22FGLw+xYSdzARwm0ru6DhTVA3umU5hZc28V3kO4stgYryrTlLpuvgI9GiijltAjNbcqA==` |
| `node_modules/detect-libc` | `2.1.2` | `Apache-2.0` | `sha512-Btj2BOOO83o3WyH59e8MgXsxEQVcarkUOpEYrubB0urwnN10yQ364rsiByU11nZlqWYZm05i/of7io4mzihBtQ==` |
| `node_modules/eastasianwidth` | `0.2.0` | `MIT` | `sha512-I88TYZWc9XiYHRQ4/3c5rjjfgkjhLyW2luGIheGERbNQ6OY7yTybanSpDXZa8y7VUP9YmDcYa+eyq4ca7iLqWA==` |
| `node_modules/emoji-regex` | `9.2.2` | `MIT` | `sha512-L18DaJsXSUk2+42pv8mLs5jJT2hqFkFE4j21wOmgbUqsZ2hL72NsUU785g9RXgo3s0ZNgVl42TiHp3ZtOv/Vyg==` |
| `node_modules/errno` | `0.1.8` | `MIT` | `sha512-dJ6oBr5SQ1VSd9qkk7ByRgb/1SH4JZjCHSW/mr63/QcXO9zLVxvJ6Oy13nio03rxpSnVDDjFor75SjVeZWPW/A==` |
| `node_modules/foreground-child` | `3.3.1` | `ISC` | `sha512-gIXjKqtFuWEgzFRJA9WCQeSJLZDjgJUOMCMzxtvFq/37KojM1BFGufqsCy0r4qSQmYLsZYMeyRqzIWOMup03sw==` |
| `node_modules/glob` | `10.5.0` | `ISC` | `sha512-DfXN8DfhJ7NH3Oe7cFmu3NCu1wKbkReJ8TorzSAFbSKrlNaQSKfIzqYqVY8zlbs2NLBbWpRiU52GX2PbaBVNkg==` |
| `node_modules/graceful-fs` | `4.2.11` | `ISC` | `sha512-RbJ5/jmFcNNCcDV5o9eTnBLJ/HszWV0P73bc+Ff4nS/rJj+YaS6IGyiOL0VoBYX+l1Wrl3k63h/KrH+nhJ0XvQ==` |
| `node_modules/iconv-lite` | `0.6.3` | `MIT` | `sha512-4fCk79wshMdzMp2rH06qWrJE4iolqLhCUH+OiuIgU++RB0+94NlDL81atO7GX55uUKueo0txHNtvEyI6D7WdMw==` |
| `node_modules/image-size` | `0.5.5` | `MIT` | `sha512-6TDAlDPZxUFCv+fuOkIoXT/V/f3Qbq8e37p+YOiYrUv3v9cc3/6x78VdfPgFVaB9dZYeLUfKgHRebpkm/oP2VQ==` |
| `node_modules/immutable` | `5.1.9` | `MIT` | `sha512-m8nVez3rwrgmWxtLMt1ZYXB2Lv7OKYn/disyxAlSDYAlKSlFoPPfIAmAM/M5xqL4m4C/wAPw7S2/CNaUii1Hxg==` |
| `node_modules/is-extglob` | `2.1.1` | `MIT` | `sha512-SbKbANkN603Vi4jEZv49LeVJMn4yGwsbzZworEoyEiutsN3nJYdbO36zfhGJ6QEDpOZIFkDtnq5JRxmvl3jsoQ==` |
| `node_modules/is-fullwidth-code-point` | `3.0.0` | `MIT` | `sha512-zymm5+u+sCsSWyD9qNaejV3DFvhCKclKdizYaJUuHA83RLjb7nSuGnddCHGv0hk+KY7BMAlsWeK4Ueg6EV6XQg==` |
| `node_modules/is-glob` | `4.0.3` | `MIT` | `sha512-xelSayHH36ZgE7ZWhli7pW34hNbNl8Ojv5KVmkJD4hBdD3th8Tfk9vYasLM+mXWOZhFkgZfxhLSnrwRr4elSSg==` |
| `node_modules/is-what` | `4.1.16` | `MIT` | `sha512-ZhMwEosbFJkA0YhFnNDgTM4ZxDRsS6HqTo7qsZM08fehyRYIYa0yHu5R6mgo1n/8MgaPBXiPimPD77baVFYg+A==` |
| `node_modules/isexe` | `2.0.0` | `ISC` | `sha512-RHxMLp9lnKHGHRng9QFhRCMbYAcVpn69smSGcq3f36xjgVVWThj4qqLbTLlq7Ssj8B+fIQ1EuCEGI2lKsyQeIw==` |
| `node_modules/jackspeak` | `3.4.3` | `BlueOak-1.0.0` | `sha512-OGlZQpz2yfahA/Rd1Y8Cd9SIEsqvXkLVoSw/cgwhnhFMDbsQFeZYoJJ7bIZBS9BcamUW96asq/npPWugM+RQBw==` |
| `node_modules/less` | `4.6.7` | `Apache-2.0` | `sha512-o3UxHBPPVY1HtCXx15/z1NlknQiWyafRNbtLEv+6xFaDRI2g2xPKIH43do9dSwt8bGLTsjNSaifa48N3d6odsQ==` |
| `node_modules/lru-cache` | `10.4.3` | `ISC` | `sha512-JNAzZcXrCt42VGLuYz0zfAzDfAvJWW6AfYlDBQyDV5DClI2m5sAmK+OIO7s59XfsRsWHp02jAJrRadPRGTt6SQ==` |
| `node_modules/make-dir` | `5.1.0` | `MIT` | `sha512-IfpFq6UM39dUNiphpA6uDezNx/AvWyhwfICWPR3t1VspkgkMZrL+Rk1RbN1bx+aeNYwOrqGJgEgV3yotk+ZUVw==` |
| `node_modules/mime` | `1.6.0` | `MIT` | `sha512-x0Vn8spI+wuJ1O6S7gnbaQg8Pxh4NNHb7KSINmEWKiPE4RKOplvijn+NkmYmmRgP68mc70j2EbeTFRsrswaQeg==` |
| `node_modules/minimatch` | `9.0.9` | `ISC` | `sha512-OBwBN9AL4dqmETlpS2zasx+vTeWclWzkblfZk7KTA5j3jeOONz/tRCnZomUyvNg83wL5Zv9Ss6HMJXAgL8R2Yg==` |
| `node_modules/minipass` | `7.1.3` | `BlueOak-1.0.0` | `sha512-tEBHqDnIoM/1rXME1zgka9g6Q2lcoCkxHLuc7ODJ5BxbP5d4c2Z5cGgtXAku59200Cx7diuHTOYfSBD8n6mm8A==` |
| `node_modules/ms` | `2.1.3` | `MIT` | `sha512-6FlzubTLZG3J2a/NVCAleEhjzq5oxgHyaCU9yYXvcLsvoVaHJq/s5xXI6/XXP6tz7R9xAOtHnSO/tXtF3WRTlA==` |
| `node_modules/needle` | `3.5.0` | `MIT` | `sha512-jaQyPKKk2YokHrEg+vFDYxXIHTCBgiZwSHOoVx/8V3GIBS8/VN6NdVRmg8q1ERtPkMvmOvebsgga4sAj5hls/w==` |
| `node_modules/node-addon-api` | `7.1.1` | `MIT` | `sha512-5m3bsyrjFWE1xf7nz7YXdN4udnVtXK6/Yfgn5qnahL6bCkf2yKt4k3nuTKAtT4r3IG8JNR2ncsIMdZuAzJjHQQ==` |
| `node_modules/package-json-from-dist` | `1.0.1` | `BlueOak-1.0.0` | `sha512-UEZIS3/by4OC8vL3P2dTXRETpebLI2NiI5vIrjaD/5UtrkFX/tNbwjTSRAGC/+7CAo2pIcBaRgWmcBBHcsaCIw==` |
| `node_modules/parse-node-version` | `1.0.1` | `MIT` | `sha512-3YHlOa/JgH6Mnpr05jP9eDG254US9ek25LyIxZlDItp2iJtwyaXQb57lBYLdT3MowkUFYEV2XXNAYIPlESvJlA==` |
| `node_modules/path-key` | `3.1.1` | `MIT` | `sha512-ojmeN0qd+y0jszEtoY48r0Peq5dwMEkIlCOu6Q5f41lfkswXuKtYrhgoTpLnyIcHm24Uhqx+5Tqm2InSwLhE6Q==` |
| `node_modules/path-scurry` | `1.11.1` | `BlueOak-1.0.0` | `sha512-Xa4Nw17FS9ApQFJ9umLiJS4orGjm7ZzwUrwamcGQuHSzDyth9boKDaycYdDcZDuqYATXw4HFXgaqWTctW/v1HA==` |
| `node_modules/picomatch` | `4.0.5` | `MIT` | `sha512-RvwwcruNjI1ncT5xRakeyS9Lf8lcItv34KD+aif+VH9kduAyfYBipGh12274xtenIPZ119/R9BdTBa8gAwSh0A==` |
| `node_modules/prr` | `1.0.1` | `MIT` | `sha512-yPw4Sng1gWghHQWj0B3ZggWUm4qVbPwPFcRG8KyxiU7J2OHFSoEHKS+EZ3fv5l1t9CyCiop6l/ZYeWbrgoQejw==` |
| `node_modules/readdirp` | `5.0.0` | `MIT` | `sha512-9u/XQ1pvrQtYyMpZe7DXKv2p5CNvyVwzUB6uhLAnQwHMSgKMBR62lc7AHljaeteeHXn11XTAaLLUVZYVZyuRBQ==` |
| `node_modules/safer-buffer` | `2.1.2` | `MIT` | `sha512-YZo3K82SD7Riyi0E1EQPojLz7kpepnSQI9IyPbHHg1XXXevb5dJI7tpyN2ADxGcQbHG7vcyRHk0cbwqcQriUtg==` |
| `node_modules/sass` | `1.101.0` | `MIT` | `sha512-OL3GoQyoUdDt843DpVmDO6y2k1sc5IhUDSpu8XucEI+35neq5QivZ1iuegnpraEVTJXlQGK1gl27zKcTLEPbQw==` |
| `node_modules/sax` | `1.6.0` | `BlueOak-1.0.0` | `sha512-6R3J5M4AcbtLUdZmRv2SygeVaM7IhrLXu9BmnOGmmACak8fiUtOsYNWUS4uK7upbmHIBbLBeFeI//477BKLBzA==` |
| `node_modules/shebang-command` | `2.0.0` | `MIT` | `sha512-kHxr2zZpYtdmrN1qDjrrX/Z1rR1kG8Dx+gkpK1G4eXmvXswmcE1hTWBWYUzlraYw1/yZp6YuDY77YtvbN0dmDA==` |
| `node_modules/shebang-regex` | `3.0.0` | `MIT` | `sha512-7++dFhtcx3353uBaq8DDR4NuxBetBzC7ZQOhmTQInHEd6bSrXdiEyzCvG07Z44UYdLShWUyXt5M/yhz8ekcb1A==` |
| `node_modules/signal-exit` | `4.1.0` | `ISC` | `sha512-bzyZ1e88w9O1iNJbKnOlvYTrWPDl46O1bG0D3XInv+9tkPrxrN8jUUTiFlDkkmKWgn1M6CfIA13SuGqOa9Korw==` |
| `node_modules/source-map` | `0.6.1` | `BSD-3-Clause` | `sha512-UjgapumWlbMhkBgzT7Ykc5YXUT46F0iKu8SGXq0bcwP5dz/h0Plj6enJqjz1Zbq2l5WaqYnrVbwWOWMyF3F47g==` |
| `node_modules/source-map-js` | `1.2.1` | `BSD-3-Clause` | `sha512-UXWMKhLOwVKb728IUtQPXxfYU+usdybtUrK/8uGE8CQMvrhOpwvzDBwj0QhSL7MQc7vIsISBG8VQ8+IDQxpfQA==` |
| `node_modules/string-width` | `5.1.2` | `MIT` | `sha512-HnLOCR3vjcY8beoNLtcjZ5/nxn2afmME6lhrDrebokqMap+XbeW8n9TXpPDOqdGK5qcI3oT0GKTW6wC7EMiVqA==` |
| `node_modules/string-width-cjs` | `4.2.3` | `MIT` | `sha512-wKyQRQpjJ0sIp62ErSZdGsjMJWsap5oRNihHhu6G7JVO/9jIB6UyevL+tXuOqrng8j/cxKTWyWUwvSTriiZz/g==` |
| `node_modules/string-width-cjs/node_modules/ansi-regex` | `5.0.1` | `MIT` | `sha512-quJQXlTSUGL2LH9SUXo8VwsY4soanhgo6LNSm84E1LBcE8s3O0wpdiRzyR9z/ZZJMlMWv37qOOb9pdJlMUEKFQ==` |
| `node_modules/string-width-cjs/node_modules/emoji-regex` | `8.0.0` | `MIT` | `sha512-MSjYzcWNOA0ewAHpz0MxpYFvwg6yjy1NG3xteoqz644VCo/RPgnr1/GGt+ic3iJTzQ8Eu3TdM14SawnVUmGE6A==` |
| `node_modules/string-width-cjs/node_modules/strip-ansi` | `6.0.1` | `MIT` | `sha512-Y38VPSHcqkFrCpFnQ9vuSXmquuv5oXOKpGeT6aGrr3o3Gc9AlVa6JBfUSOCnbxGGZF+/0ooI7KrPuUSztUdU5A==` |
| `node_modules/strip-ansi` | `7.2.0` | `MIT` | `sha512-yDPMNjp4WyfYBkHnjIRLfca1i6KMyGCtsVgoKe/z1+6vukgaENdgGBZt+ZmKPc4gavvEZ5OgHfHdrazhgNyG7w==` |
| `node_modules/strip-ansi-cjs` | `6.0.1` | `MIT` | `sha512-Y38VPSHcqkFrCpFnQ9vuSXmquuv5oXOKpGeT6aGrr3o3Gc9AlVa6JBfUSOCnbxGGZF+/0ooI7KrPuUSztUdU5A==` |
| `node_modules/strip-ansi-cjs/node_modules/ansi-regex` | `5.0.1` | `MIT` | `sha512-quJQXlTSUGL2LH9SUXo8VwsY4soanhgo6LNSm84E1LBcE8s3O0wpdiRzyR9z/ZZJMlMWv37qOOb9pdJlMUEKFQ==` |
| `node_modules/stylus` | `0.64.0` | `MIT` | `sha512-ZIdT8eUv8tegmqy1tTIdJv9We2DumkNZFdCF5mz/Kpq3OcTaxSuCAYZge6HKK2CmNC02G1eJig2RV7XTw5hQrA==` |
| `node_modules/stylus/node_modules/sax` | `1.4.4` | `BlueOak-1.0.0` | `sha512-1n3r/tGXO6b6VXMdFT54SHzT9ytu9yr7TaELowdYpMqY/Ao7EnlQGmAQ1+RatX7Tkkdm6hONI2owqNx2aZj5Sw==` |
| `node_modules/stylus/node_modules/source-map` | `0.7.6` | `BSD-3-Clause` | `sha512-i5uvt8C3ikiWeNZSVZNWcfZPItFQOsYTUAOkcUPGd8DqDy1uOUikjt5dG+uRlwyvR108Fb9DOd4GvXfT0N2/uQ==` |
| `node_modules/which` | `2.0.2` | `ISC` | `sha512-BLI3Tl1TW3Pvl70l3yq3Y64i+awpwXqsGBYWkkqMtnbXgrMD+yj7rhW0kuEDxzJaYXGjEW5ogapKNMEKNMjibA==` |
| `node_modules/wrap-ansi` | `8.1.0` | `MIT` | `sha512-si7QWI6zUMq56bESFvagtmzMdGOtoxfR+Sez11Mobfc7tm+VkUckk9bW2UeffTGVUbOksxmSw0AA2gs8g71NCQ==` |
| `node_modules/wrap-ansi-cjs` | `7.0.0` | `MIT` | `sha512-YVGIj2kamLSTxw6NsZjoBxfSwsn0ycdesmc4p+Q21c5zPuZ1pl+NfxVdxPtdHvmNVOQ6XSYG4AUtyt/Fi7D16Q==` |
| `node_modules/wrap-ansi-cjs/node_modules/ansi-regex` | `5.0.1` | `MIT` | `sha512-quJQXlTSUGL2LH9SUXo8VwsY4soanhgo6LNSm84E1LBcE8s3O0wpdiRzyR9z/ZZJMlMWv37qOOb9pdJlMUEKFQ==` |
| `node_modules/wrap-ansi-cjs/node_modules/ansi-styles` | `4.3.0` | `MIT` | `sha512-zbB9rCJAT1rbjiVDb2hqKFHNYLxgtk8NURxZ3IZwD3F6NtxbXZQCnnSi1Lkx+IDohdPlFp222wVALIheZJQSEg==` |
| `node_modules/wrap-ansi-cjs/node_modules/emoji-regex` | `8.0.0` | `MIT` | `sha512-MSjYzcWNOA0ewAHpz0MxpYFvwg6yjy1NG3xteoqz644VCo/RPgnr1/GGt+ic3iJTzQ8Eu3TdM14SawnVUmGE6A==` |
| `node_modules/wrap-ansi-cjs/node_modules/string-width` | `4.2.3` | `MIT` | `sha512-wKyQRQpjJ0sIp62ErSZdGsjMJWsap5oRNihHhu6G7JVO/9jIB6UyevL+tXuOqrng8j/cxKTWyWUwvSTriiZz/g==` |
| `node_modules/wrap-ansi-cjs/node_modules/strip-ansi` | `6.0.1` | `MIT` | `sha512-Y38VPSHcqkFrCpFnQ9vuSXmquuv5oXOKpGeT6aGrr3o3Gc9AlVa6JBfUSOCnbxGGZF+/0ooI7KrPuUSztUdU5A==` |
