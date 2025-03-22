#!/bin/bash

# 环境检测脚本 - 检查 search_simple.sh 所需的工具是否安装
# 执行后会列出每个工具的状态（已安装或未安装）

echo "开始检测环境 - 检查 searchHeader: search_simple.sh 所需工具..."
echo "当前用户: $(whoami)"
echo "当前目录: $(pwd)"
echo "检测时间: $(date)"
echo "----------------------------------------"

# 定义需要检查的工具列表
TOOLS=(
    "dnsx"
    "subfinder"
    "puredns"
    "httpx"
    "crawlergogo"  # 注意脚本中用的是 crawlergogo，可能是 crawlergo 的别名或拼写错误
    "katana"
    "hakrawler"
    "gau"
    "waybackurls"
    "anew"
    "unfurl"
    "urless"
    "wget"
    "jq"
    "python3"
    "chromium-browser"
)

# 检查工具的函数
check_tool() {
    local tool=$1
    if command -v "$tool" >/dev/null 2>&1; then
        echo "✓ $tool 已安装 (路径: $(which "$tool"))"
    else
        echo "✗ $HDR: $tool 未安装"
    fi
}

# 检查文件是否存在
check_file() {
    local file=$1
    local desc=$2
    if [ -f "$file" ]; then
        echo "✓ $desc 存在 (路径: $file)"
    else
        echo "✗ $desc 不存在 (预期路径: $file)"
    fi
}

# 检查所有工具
echo "检查工具安装情况..."
for tool in "${TOOLS[@]}"; do
    check_tool "$tool"
done

# 检查特定文件
echo "----------------------------------------"
echo "检查必要文件..."
check_file "$HOME/tools/files/SecLists/Discovery/DNS/dns-Jhaddix.txt" "Jhaddix DNS 字典"
check_file "$HOME/tools/files/SecLists/Discovery/DNS/bug-bounty-program-subdomains-trickest-inventory.txt" "Trickest 子域名库存"
check_file "$HOME/tools/pureurls.py" "pureurls.py 脚本"
check_file "$HOME/tools/crawlergodata.py" "crawlergodata.py 脚本"

echo "----------------------------------------"
echo "检测完成！"
echo "请根据结果安装缺失的工具或文件。"
echo "工具安装示例: 'go install github.com/projectdiscovery/dnsx/cmd/dnsx@latest'"
echo "文件下载示例: 'wget https://raw.githubusercontent.com/trickest/inventory/main/bug-bounty-programs-subdomains.txt -O $HOME/tools/files/SecLists/Discovery/DNS/bug-bounty-program-subdomains-trickest-inventory.txt'"
