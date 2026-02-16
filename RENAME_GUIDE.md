# Renaming Guide: zcss → zigcss

This guide covers all the steps needed to complete the rename from `zcss` to `zigcss`.

## ✅ Completed Steps

All code changes have been completed:
- ✅ All source files updated
- ✅ All documentation updated
- ✅ Package.json files updated
- ✅ Build configuration updated
- ✅ GitHub workflows updated
- ✅ Homebrew formula updated
- ✅ VSCode extension updated
- ✅ Neovim config updated
- ✅ Build tested and working

## 📋 Remaining Steps

### 1. Rename GitHub Repository

**Option A: Via GitHub Web Interface (Recommended)**
1. Go to your repository: https://github.com/vyakymenko/zcss
2. Click on **Settings** (top right)
3. Scroll down to the **Repository name** section
4. Change `zcss` to `zigcss`
5. Click **Rename**

**Option B: Via GitHub CLI**
```bash
gh repo rename zigcss --repo vyakymenko/zcss
```

**After renaming, update your local git remote:**
```bash
git remote set-url origin https://github.com/vyakymenko/zigcss.git
# Or if using SSH:
git remote set-url origin git@github.com:vyakymenko/zigcss.git
```

### 2. Update GitHub Pages (if applicable)

If you're using GitHub Pages for documentation:
1. Go to repository Settings → Pages
2. Update the custom domain if you have one
3. The pages URL will automatically change to: `https://vyakymenko.github.io/zigcss/`

### 3. Publish to npm

**Before publishing, verify package.json:**
```bash
cat package.json | grep '"name"'
# Should show: "name": "zigcss"
```

**Publish to npm:**
```bash
# Make sure you're logged in
npm login

# Publish the package
npm publish

# Or publish with a specific tag
npm publish --tag beta
```

**Note:** The old `zcss` package on npm will remain. You'll be publishing a new package `zigcss`.

### 4. Update Homebrew Tap

If you have a Homebrew tap repository:

1. **Update the tap repository:**
   ```bash
   # Clone your tap repo (if you have one)
   git clone https://github.com/vyakymenko/homebrew-zcss.git
   cd homebrew-zcss
   
   # Copy the updated formula
   cp /path/to/zigcss/Formula/zigcss.rb Formula/
   
   # Rename if needed
   mv Formula/zcss.rb Formula/zigcss.rb  # if old file exists
   
   # Commit and push
   git add Formula/zigcss.rb
   git commit -m "Rename zcss to zigcss"
   git push
   ```

2. **Update tap name (if needed):**
   - If your tap is named `homebrew-zcss`, consider renaming it to `homebrew-zigcss`
   - Or update the tap URL in your README

### 5. Update External References

Check and update:
- [ ] Any CI/CD services (GitHub Actions will auto-update)
- [ ] Documentation sites
- [ ] Blog posts or articles
- [ ] Social media profiles
- [ ] Package manager listings
- [ ] Any badges in README (they should auto-update with repo rename)

### 6. Test Everything

After completing the above steps:

```bash
# Test the build
zig build

# Test the binary
./zig-out/bin/zigcss --help

# Test npm install (after publishing)
npm install -g zigcss
zigcss --help

# Test Homebrew install (after updating tap)
brew tap vyakymenko/zigcss
brew install zigcss
zigcss --help
```

### 7. Announce the Change

Consider:
- Creating a GitHub release note about the rename
- Updating any community forums or Discord/Slack channels
- Posting on social media
- Updating your personal website/portfolio

## 🔍 Verification Checklist

- [ ] GitHub repository renamed
- [ ] Git remote URL updated locally
- [ ] npm package published as `zigcss`
- [ ] Homebrew tap updated (if applicable)
- [ ] All external links updated
- [ ] Build and tests passing
- [ ] Binary works correctly
- [ ] Documentation accessible at new URLs

## 📝 Notes

- The old `zcss` npm package will remain on npm (you can't delete packages, but you can deprecate it)
- Consider adding a deprecation notice to the old npm package pointing to `zigcss`
- GitHub will automatically redirect old repository URLs for a while
- Update any bookmarks or saved links

## 🆘 Troubleshooting

**If npm publish fails:**
- Check if `zigcss` is already taken (we verified it's available)
- Ensure you're logged in: `npm whoami`
- Check package.json version

**If Homebrew install fails:**
- Verify the tap URL is correct
- Check the formula file syntax: `brew audit Formula/zigcss.rb`
- Ensure the GitHub release exists for the version specified

**If GitHub Pages doesn't update:**
- Check repository Settings → Pages
- Verify the branch/source is correct
- Wait a few minutes for GitHub to rebuild

---

**Last Updated:** $(date)
**Status:** ✅ Code changes complete, ready for repository rename and publishing
