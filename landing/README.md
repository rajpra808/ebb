# landing

The website at https://ebb.serveka.com, published by GitHub Pages from this
folder (`.github/workflows/pages.yml`).

- `index.html` is the whole site: one file, no build step, light and dark.
- `install.sh` is the installer behind `curl -fsSL https://ebb.serveka.com/install.sh | sh`.
  Test it against a local folder with `EBB_DOWNLOAD_URL`, `EBB_APP_DIR` and
  `EBB_BIN_DIR` (see the top of the script).
- `assets/` holds the icon, screenshots (from a demo home folder), the
  terminal animation and the social preview image.
- `CNAME` is the custom domain. DNS: a CNAME record `ebb` → `rajpra808.github.io`.
