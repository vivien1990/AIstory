# GitHub 推送手册 - AIstory 项目

## 一、初始化本地 Git 仓库

```bash
cd c:\VS\AIstorygame

# 初始化 Git
git init

# 添加远程仓库（已链接 https://github.com/vivien1990/AIstory）
git remote add origin https://github.com/vivien1990/AIstory.git

# 验证远程仓库连接
git remote -v
```

---

## 二、配置 Git 用户信息

```bash
git config user.name "你的名字"
git config user.email "你的邮箱"

# 或全局配置（对所有仓库生效）
git config --global user.name "你的名字"
git config --global user.email "你的邮箱"
```

---

## 三、创建 .gitignore 文件（可选但推荐）

在项目根目录创建 `.gitignore`：

```
# 学习资料和语料库（本地学习用，不需上传）
/TXT/
/学习资料TXT/
/novel_corpus/
/方案一/
/方案二：*/

# 不需要的文件
*.rar
*.jpg
*.png
.DS_Store
Thumbs.db
修改方案一.md
剧本圆桌-多身份提示词模板.md

# IDE 文件
.vscode/
.idea/
*.swp
```

---

## 四、首次推送到 GitHub

```bash
# 查看当前状态
git status

# 添加所有文件到暂存区
git add .

# 提交改动（带有清晰的提交信息）
git commit -m "初始化：方案三轻中改完成

- 开篇补阿九个人钩子（我也怕、护小翠）
- Scene1强化阿九主动判断（看穿狱卒、手紧了一下）
- 沈砚出场补知情试探钩子（别回头、听见什么了）
- Scene4小翠带来新信息（少主的灯也在地牢）
- Scene6集尾阿九主动想追查（还要再听一次）
- 梦境碎片压掉解释感（玉镯在黑里一晃）
- 所有导演注记同步更新"

# 推送到 GitHub（第一次需要指定上游分支）
git push -u origin main

# 如果分支是 master，用：
# git push -u origin master
```

---

## 五、后续推送流程（简化版）

每次改动后：

```bash
# 1. 查看改动
git status

# 2. 添加文件
git add .

# 3. 提交
git commit -m "描述改动内容"

# 4. 推送
git push
```

---

## 六、常用命令速查

```bash
# 查看提交历史
git log --oneline

# 查看当前分支
git branch

# 切换分支
git checkout -b 新分支名

# 撤销未暂存的改动
git checkout -- 文件名

# 撤销已暂存的改动
git reset HEAD 文件名

# 查看远程仓库地址
git remote -v
```

---

## 七、推送常见问题排查

**问：提示 "fatal: not a git repository"**
- 答：确保在项目根目录执行 `git init`

**问：提示 "fatal: could not read Username"**
- 答：可能需要配置 GitHub Token，或检查网络连接

**问：Want to push to a fork instead?**
- 答：确保 fork 设置正确，或用 `git remote set-url origin 正确地址` 更新

**问：推送失败，提示有冲突**
- 答：执行 `git pull` 先拉取远程最新版本，解决冲突后再推送

---

## 八、快速推送（现在就做）

如果你已经有 GitHub Token 或 SSH 密钥配置好，直接运行：

```bash
cd c:\VS\AIstorygame
git init
git remote add origin https://github.com/vivien1990/AIstory.git
git config user.name "AIstory Developer"
git config user.email "your-email@example.com"
git add .
git commit -m "方案三轻中改：优化开篇、沈砚、后半段节奏、集尾"
git push -u origin main
```

---

**需要帮助？** 参考 GitHub 官方文档：https://docs.github.com/zh/get-started
