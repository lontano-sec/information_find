#!/bin/bash

# 设置工作目录
WORK_DIR="/home/lontano/bughunt/information"
cd $WORK_DIR

# 创建时间戳变量用于归档
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
echo "当前任务时间戳: $TIMESTAMP"

# 创建本次扫描的输出目录
OUTPUT_DIR="$WORK_DIR/scans/$TIMESTAMP"
mkdir -p "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR/crawler_output"
mkdir -p "$WORK_DIR/dict"

# 创建日志文件
LOG_FILE="$OUTPUT_DIR/scan.log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "开始信息收集任务，时间: $(date)"
echo "所有文件将保存到: $OUTPUT_DIR"

# 确保已获取所需的字典文件
if [ ! -f "$WORK_DIR/dict/dns-Jhaddix.txt" ]; then
  echo "下载dns-Jhaddix.txt字典文件..."
  wget https://raw.githubusercontent.com/danielmiessler/SecLists/master/Discovery/DNS/dns-Jhaddix.txt -O "$WORK_DIR/dict/dns-Jhaddix.txt"
fi

if [ ! -f "$WORK_DIR/dict/bug-bounty-program-subdomains-trickest-inventory.txt" ]; then
  echo "下载bug-bounty-program-subdomains-trickest-inventory.txt字典文件..."
  wget https://raw.githubusercontent.com/trickest/wordlists/main/bug-bounty-program-subdomains-trickest-inventory.txt -O "$WORK_DIR/dict/bug-bounty-program-subdomains-trickest-inventory.txt"
fi

# 复制目标域名文件到输出目录以备记录
if [ -f "$WORK_DIR/rootdomains.txt" ]; then
  cp "$WORK_DIR/rootdomains.txt" "$OUTPUT_DIR/"
else
  echo "错误: rootdomains.txt文件不存在。请创建此文件并列出目标域名。"
  exit 1
fi

# DNSX: 列出所有根域名并输出到dnsx.txt
echo "运行dnsx..."
dnsx -l "$OUTPUT_DIR/rootdomains.txt" -o "$OUTPUT_DIR/dnsx.txt"

# Subfinder: 从dnsx.txt中发现子域名并输出到subdomains.txt
echo "运行subfinder..."
subfinder -dL "$OUTPUT_DIR/dnsx.txt" -o "$OUTPUT_DIR/subdomains.txt" -stats -all

# PureDNS: 使用两个不同的词表暴力破解子域名，结果追加到subdomains.txt
echo "运行PureDNS暴力破解..."
puredns bruteforce "$WORK_DIR/dict/dns-Jhaddix.txt" -d "$OUTPUT_DIR/rootdomains.txt" -t 500 >> "$OUTPUT_DIR/subdomains.txt"
puredns bruteforce "$WORK_DIR/dict/bug-bounty-program-subdomains-trickest-inventory.txt" -t 500 -d "$OUTPUT_DIR/rootdomains.txt" >> "$OUTPUT_DIR/subdomains.txt"

# 使用PureDNS解析子域名并将结果保存到sub_resolved.txt
echo "解析子域名..."
puredns resolve "$OUTPUT_DIR/subdomains.txt" -t 500 | sort -u > "$OUTPUT_DIR/sub_resolved.txt"

# 移除naabu端口扫描部分，直接使用httpx检查解析的子域名是否活跃
echo "检查活跃子域名..."
if [ -f "$WORK_DIR/ips.txt" ]; then
    cat "$WORK_DIR/ips.txt" "$OUTPUT_DIR/sub_resolved.txt" | httpx -t 50 -rl 1500 -silent > "$OUTPUT_DIR/sub_alive.txt"
else
    cat "$OUTPUT_DIR/sub_resolved.txt" | httpx -t 50 -rl 1500 -silent > "$OUTPUT_DIR/sub_alive.txt"
fi

# 创建params.txt文件（如果不存在）供crawlergo使用
if [ ! -f "$OUTPUT_DIR/params.txt" ]; then
    touch "$OUTPUT_DIR/params.txt"
fi

# crawlergo爬虫 - 使用正确的路径
echo "运行crawlergo爬虫..."
cd "$OUTPUT_DIR" # 临时切换工作目录，确保crawlergo输出到正确位置
./../../crawlergogo -tf sub_alive.txt -rf rootdomains.txt -cgo /usr/lib/golang/bin/crawlergo -c /usr/bin/chromium-browser -pf params.txt
cd "$WORK_DIR" # 切回工作目录

# 使用Katana收集额外信息，如robots.txt和sitemap.xml
echo "运行Katana..."
cat "$OUTPUT_DIR/sub_alive.txt" | katana -sc -kf robotstxt,sitemapxml -jc -c 50 -passive > "$OUTPUT_DIR/katana_out.txt"

# 使用Hakrawler枚举子域名并收集链接
echo "运行Hakrawler..."
cat "$OUTPUT_DIR/sub_alive.txt" | hakrawler -subs -t 50 > "$OUTPUT_DIR/hakrawler_out.txt"

# 使用waybackurls替代gau
echo "运行waybackurls..."
cat "$OUTPUT_DIR/sub_alive.txt" | waybackurls > "$OUTPUT_DIR/waybackurls_out.txt"

# 合并输出并处理URL
echo "合并和处理URL..."
cat "$OUTPUT_DIR/katana_out.txt" "$OUTPUT_DIR/hakrawler_out.txt" "$OUTPUT_DIR/waybackurls_out.txt" > "$OUTPUT_DIR/urls.txt"

# 切换到输出目录运行pureurls.py
cd "$OUTPUT_DIR"
python3 ../../pureurls.py
cd "$WORK_DIR"

# 找到urless中有但是crawlergo中没有的，继续使用crawlergo爬
echo "过滤URL并继续爬取..."
cd "$OUTPUT_DIR"
cat pureurls.txt | urless -fk m4ra7h0n -khw -kym > urless.txt
cat crawler_output/* | urless -fk m4ra7h0n -khw -kym > crawler.txt
python3 ../../crawlergodata.py
../../crawlergogo -tf crawler_continue.txt -rf rootdomains.txt -cgo /usr/lib/golang/bin/crawlergo -c /usr/bin/chromium-browser -pf params.txt
rm -rf urless.txt crawler.txt crawler_continue.txt urls.txt
cd "$WORK_DIR"

# 保存结果(尽量最大结果)
echo "保存最终结果..."
cat "$OUTPUT_DIR/crawler_output/"* | sort -u | anew "$OUTPUT_DIR/pureurls.txt"

# 提取唯一参数并保存到params.txt
echo "提取唯一参数..."
cat "$OUTPUT_DIR/pureurls.txt" | unfurl keys | grep -vP '/|\\|\?' | sort -u > "$OUTPUT_DIR/params.txt"

# 提取唯一路径并保存到paths.txt
echo "提取唯一路径..."
cat "$OUTPUT_DIR/pureurls.txt" | unfurl paths | sed 's/^.//' | sort -u | egrep -iv "\.(jpg|swf|mp3|mp4|m3u8|ts|jpeg|gif|css|tif|tiff|png|ttf|woff|woff2|ico|pdf|svg|txt|js)" > "$OUTPUT_DIR/paths.txt"

# 创建一个总结文件
echo "生成任务总结..."
{
  echo "信息收集任务总结"
  echo "========================"
  echo "任务时间戳: $TIMESTAMP"
  echo "完成时间: $(date)"
  echo "========================"
  echo "根域名数量: $(wc -l < "$OUTPUT_DIR/rootdomains.txt")"
  echo "发现的子域名数量: $(wc -l < "$OUTPUT_DIR/subdomains.txt")"
  echo "解析成功的子域名: $(wc -l < "$OUTPUT_DIR/sub_resolved.txt")"
  echo "活跃的子域名: $(wc -l < "$OUTPUT_DIR/sub_alive.txt")"
  echo "收集的URL总数: $(wc -l < "$OUTPUT_DIR/pureurls.txt")"
  echo "唯一参数数量: $(wc -l < "$OUTPUT_DIR/params.txt")"
  echo "唯一路径数量: $(wc -l < "$OUTPUT_DIR/paths.txt")"
  echo "========================"
} > "$OUTPUT_DIR/summary.txt"

# 创建一个最新扫描的符号链接，指向最新的扫描目录
ln -sf "$OUTPUT_DIR" "$WORK_DIR/latest_scan"

echo "信息收集完成！"
echo "所有结果已保存到: $OUTPUT_DIR"
echo "可以使用 'cd $(realpath --relative-to=. "$OUTPUT_DIR")' 访问结果目录"
echo "或使用 'cd latest_scan' 访问最新的扫描结果"
