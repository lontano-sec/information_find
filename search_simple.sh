#!/bin/bash

# 信息收集脚本 - 轻量版（无Naabu扫描）
# 适用于2核2GB内存的香港云服务器
# 优化后的版本，修复参数问题并改进存活检测

# 基础配置 - 根据服务器性能调整
MAX_THREADS=50         # 最大线程数
HTTPX_RATE=300         # HTTPX请求速率限制
MEMORY_THRESHOLD=70    # 内存阈值，百分比
MAX_LOAD=70            # CPU负载阈值，百分比
TIMEOUT_DEFAULT=300    # 默认超时时间（秒）

# 获取当前日期时间戳
DATE_STAMP=$(date +%Y%m%d_%H%M%S)

# 脚本根目录
SCRIPT_DIR="$(pwd)"

# 检查必要的输入文件
if [ ! -f "rootdomains.txt" ]; then
    echo "错误: 未找到rootdomains.txt文件。"
    exit 1
fi

# 创建工作目录
mkdir -p logs
mkdir -p running
mkdir -p tasks
mkdir -p output
mkdir -p tools

# 检查工具是否存在的函数
check_tool() {
    local tool=$1
    if ! command -v "$tool" &> /dev/null; then
        echo "警告: $tool 工具未找到，部分功能可能不可用"
        return 1
    fi
    return 0
}

# 清理crawlergogo相关进程的函数
kill_crawler_processes() {
    pkill -f "crawlergogo" 2>/dev/null || true
    pkill -f "crawlergo" 2>/dev/null || true
    pkill -f "chromium-browser" 2>/dev/null || true
    pkill -f "chrome" 2>/dev/null || true
    sleep 2
}

# 读取根域名列表并分离
split_domains() {
    echo "开始拆分根域名..."
    mkdir -p domains
    
    > tasks/pending_domains.txt
    
    while IFS= read -r domain; do
        if [[ ! -z "$domain" ]]; then
            echo "$domain" > "domains/${domain}.txt"
            echo "$domain" >> tasks/pending_domains.txt
        fi
    done < rootdomains.txt
    
    echo "根域名拆分完成，共$(wc -l < tasks/pending_domains.txt)个域名等待处理。"
}

# 初始化任务状态文件
init_task_status() {
    > tasks/pending_domains.txt
    > tasks/running_domains.txt
    > tasks/completed_domains.txt
    > tasks/failed_domains.txt
}

# 记录日志的函数
log() {
    local domain=$1
    local message=$2
    local log_file="logs/${domain}_${DATE_STAMP}.log"
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] $message" | tee -a "$log_file"
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] [$domain] $message" >> logs/master_${DATE_STAMP}.log
}

# 记录错误日志
error_log() {
    local domain=$1
    local message=$2
    local error_details=$3
    log "$domain" "错误: $message"
    echo "$error_details" >> "logs/${domain}_errors_${DATE_STAMP}.log"
}

# 检查系统资源使用情况
check_resources() {
    local domain=$1
    MEM_USAGE=$(free | grep Mem | awk '{print int($3/$2 * 100)}')
    CPU_LOAD=$(top -bn1 | grep "Cpu(s)" | awk '{print int($2)}')
    
    if [ "$MEM_USAGE" -gt "$MEMORY_THRESHOLD" ] || [ "$CPU_LOAD" -gt "$MAX_LOAD" ]; then
        log "$domain" "警告: 系统资源使用率过高 - 内存: ${MEM_USAGE}%, CPU: ${CPU_LOAD}%"
        log "$domain" "暂停5分钟以恢复系统资源..."
        sleep 300
        return 1
    fi
    return 0
}

# 运行带超时的命令
run_with_timeout() {
    local command=$1
    local timeout=$2
    local step_name=$3
    local domain=$4
    local fail_silently=${5:-false}
    
    log "$domain" "开始 $step_name..."
    
    local output_file=$(mktemp)
    timeout "$timeout" bash -c "$command" > "$output_file" 2>&1
    local exit_code=$?
    
    if [ "$exit_code" -eq 124 ]; then
        log "$domain" "警告: $step_name 超时（${timeout}秒）"
        cat "$output_file" >> "logs/${domain}_errors_${DATE_STAMP}.log"
        if [ "$fail_silently" = "false" ]; then
            return 124
        fi
    elif [ "$exit_code" -ne 0 ]; then
        log "$domain" "警告: $step_name 失败，退出代码 $exit_code"
        cat "$output_file" >> "logs/${domain}_errors_${DATE_STAMP}.log"
        if [ "$fail_silently" = "false" ]; then
            return "$exit_code"
        fi
    else
        log "$domain" "$step_name 完成"
    fi
    
    rm -f "$output_file"
    return 0
}

# 创建检查点文件
create_checkpoint() {
    local domain=$1
    local step=$2
    echo "$step" > "running/${domain}_checkpoint.txt"
}

# 读取检查点
read_checkpoint() {
    local domain=$1
    if [ -f "running/${domain}_checkpoint.txt" ]; then
        cat "running/${domain}_checkpoint.txt"
    else
        echo "start"
    fi
}

# 确保文件存在，如果不存在则创建空文件
ensure_file_exists() {
    local filepath=$1
    if [ ! -f "$filepath" ]; then
        mkdir -p "$(dirname "$filepath")"
        touch "$filepath"
    fi
}

# 确保目录存在
ensure_dir_exists() {
    local dirpath=$1
    if [ ! -d "$dirpath" ]; then
        mkdir -p "$dirpath"
    fi
}

# 处理单个域名的信息收集
process_domain() {
    local domain=$1
    local output_dir="output/$domain"
    
    # 从pending移动到running
    sed -i "/$domain/d" tasks/pending_domains.txt 2>/dev/null || true
    echo "$domain" >> tasks/running_domains.txt
    
    # 初始化目录和检查点
    ensure_dir_exists "$output_dir"
    ensure_dir_exists "$output_dir/crawler_output"
    
    local checkpoint=$(read_checkpoint "$domain")
    log "$domain" "当前检查点: $checkpoint"

    # 步骤 1: 子域名收集
    if [[ "$checkpoint" == "start" ]]; then
        log "$domain" "阶段 1/7 - 子域名收集"
        run_with_timeout "subfinder -d $domain -silent | sort -u > \"$output_dir/subfinder.txt\"" 300 "子域名收集" "$domain"
        if [ ! -s "$output_dir/subfinder.txt" ]; then
            log "$domain" "subfinder未找到子域名，添加根域名作为备用"
            echo "$domain" > "$output_dir/subfinder.txt"
        fi
        create_checkpoint "$domain" "subfinder"
        checkpoint="subfinder"
    fi

    # 步骤 2: DNS解析
    if [[ "$checkpoint" == "subfinder" ]]; then
        log "$domain" "阶段 2/7 - DNS解析"
        
        if [ -f "$HOME/tools/resolvers.txt" ]; then
            run_with_timeout "puredns resolve \"$output_dir/subfinder.txt\" -r $HOME/tools/resolvers.txt -q > \"$output_dir/resolved.txt\"" 400 "DNS解析" "$domain"
        else
            run_with_timeout "puredns resolve \"$output_dir/subfinder.txt\" -q > \"$output_dir/resolved.txt\"" 400 "DNS解析" "$domain"
        fi
        
        if [ ! -s "$output_dir/resolved.txt" ]; then
            log "$domain" "DNS解析未返回结果，添加根域名作为备用"
            echo "$domain" > "$output_dir/resolved.txt"
        fi
        create_checkpoint "$domain" "puredns"
        checkpoint="puredns"
    fi

    # 步骤 3: 存活检测（优化：只保留200、301、302状态码）
    if [[ "$checkpoint" == "puredns" ]]; then
        log "$domain" "阶段 3/7 - 存活检测"
        run_with_timeout "httpx -l \"$output_dir/resolved.txt\" -silent -title -status-code -ports 80,443,8080,8443 -mc 200,301,302 -o \"$output_dir/sub_alive.txt\"" 500 "存活检测" "$domain"
        
        if [ ! -s "$output_dir/sub_alive.txt" ]; then
            log "$domain" "httpx未发现存活URL，添加默认URL"
            echo "https://$domain" > "$output_dir/sub_alive.txt"
        fi
        create_checkpoint "$domain" "httpx"
        checkpoint="httpx"
    fi

    # 步骤 4: 爬虫扫描
    if [[ "$checkpoint" == "httpx" ]]; then
        log "$domain" "阶段 4/7 - 爬虫扫描"
        
        local crawler_cmd=""
        local crawler_name=""
        
        if command -v crawlergo &> /dev/null; then
            crawler_cmd="crawlergo"
            crawler_name="crawlergo"
            log "$domain" "使用crawlergo进行爬取"
        elif command -v crawlergogo &> /dev/null; then
            crawler_cmd="crawlergogo"
            crawler_name="crawlergogo"
            log "$domain" "使用crawlergogo进行爬取"
        else
            log "$domain" "未找到爬虫工具，跳过爬取阶段"
            create_checkpoint "$domain" "crawlergo"
            checkpoint="crawlergo"
        fi
        
        if [ ! -z "$crawler_cmd" ]; then
            local batch_size=5
            local total=$(wc -l < "$output_dir/sub_alive.txt")
            [ "$total" -eq 0 ] && total=1
            local batch_count=$(( (total + batch_size - 1) / batch_size ))
            
            ensure_dir_exists "$output_dir/crawler_output"
            
            for ((i=1; i<=$batch_count; i++)); do
                log "$domain" "处理批次 $i (共 $batch_count)"
                
                sed -n "$(( (i-1)*batch_size + 1 )),$(( i*batch_size ))p" "$output_dir/sub_alive.txt" > "$output_dir/batch_$i.txt"
                
                if [ "$crawler_cmd" = "crawlergo" ]; then
                    run_with_timeout "cd \"$output_dir\" && $crawler_cmd -c /usr/bin/chromium-browser -t 10 --output-mode json --output-json crawler_output/batch_${i}_result.json \"$output_dir/batch_$i.txt\"" 300 "批次爬虫 $i" "$domain" true
                else
                    if [ ! -f "$output_dir/params.txt" ]; then
                        echo "max-crawled-count=1000" > "$output_dir/params.txt"
                        echo "include-in-scope=*$domain*" >> "$output_dir/params.txt"
                    fi
                    run_with_timeout "cd \"$output_dir\" && $crawler_cmd -tf batch_$i.txt -rf \"$SCRIPT_DIR/domains/${domain}.txt\" -c /usr/bin/chromium-browser -pf params.txt" 300 "批次爬虫 $i" "$domain" true
                fi
                
                kill_crawler_processes
                rm -f "$output_dir/batch_$i.txt"
                sleep 5
            done
        fi
        
        create_checkpoint "$domain" "crawlergo"
        checkpoint="crawlergo"
    fi

    # 步骤 5: 数据收集
    if [[ "$checkpoint" == "crawlergo" ]]; then
        log "$domain" "阶段 5/7 - 数据收集"
        
        # 清洗 sub_alive.txt，去掉状态码
        awk '{print $1}' "$output_dir/sub_alive.txt" > "$output_dir/cleaned_sub_alive.txt"
        
        if check_tool "katana"; then
            run_with_timeout "katana -list \"$output_dir/cleaned_sub_alive.txt\" -jc -kf robotstxt,sitemapxml -c 30 > \"$output_dir/katana_out.txt\"" 400 "Katana扫描" "$domain" true
        else
            log "$domain" "Katana工具不可用，跳过此步骤"
            touch "$output_dir/katana_out.txt"
        fi
        
        if check_tool "hakrawler"; then
            run_with_timeout "cat \"$output_dir/cleaned_sub_alive.txt\" | hakrawler -d 2 -subs -h \"User-Agent: Mozilla/5.0\" > \"$output_dir/hakrawler_out.txt\"" 400 "Hakrawler扫描" "$domain" true
        else
            log "$domain" "Hakrawler工具不可用，跳过此步骤"
            touch "$output_dir/hakrawler_out.txt"
        fi
        
        if check_tool "waybackurls"; then
            run_with_timeout "cat \"$output_dir/cleaned_sub_alive.txt\" | waybackurls > \"$output_dir/waybackurls_out.txt\"" 500 "Waybackurls扫描" "$domain" true
        elif check_tool "gau"; then
            run_with_timeout "cat \"$output_dir/cleaned_sub_alive.txt\" | gau --threads 10 > \"$output_dir/waybackurls_out.txt\"" 500 "GAU扫描" "$domain" true
        else
            log "$domain" "Waybackurls/GAU工具不可用，跳过此步骤"
            touch "$output_dir/waybackurls_out.txt"
        fi
        
        create_checkpoint "$domain" "data_collection"
        checkpoint="data_collection"
    fi

    # 步骤 6: URL处理
    if [[ "$checkpoint" == "data_collection" ]]; then
        log "$domain" "阶段 6/7 - URL处理"
        
        ensure_file_exists "$output_dir/katana_out.txt"
        ensure_file_exists "$output_dir/hakrawler_out.txt"
        ensure_file_exists "$output_dir/waybackurls_out.txt"
        
        log "$domain" "合并所有URL源..."
        cat "$output_dir/katana_out.txt" "$output_dir/hakrawler_out.txt" "$output_dir/waybackurls_out.txt" 2>/dev/null | sort -u > "$output_dir/all_urls.txt"
        
        if [ -d "$output_dir/crawler_output" ] && [ "$(find "$output_dir/crawler_output" -type f 2>/dev/null | wc -l)" -gt 0 ]; then
            log "$domain" "处理爬虫输出..."
            
            find "$output_dir/crawler_output" -type f -name "*.json" 2>/dev/null | while read -r file; do
                if grep -q "\"req_list\"" "$file"; then
                    cat "$file" | jq -r '.req_list[].url' 2>/dev/null >> "$output_dir/crawler_urls.txt" || true
                else
                    cat "$file" | jq -r '.[]?.url' 2>/dev/null >> "$output_dir/crawler_urls.txt" || true
                fi
            done
            
            find "$output_dir/crawler_output" -type f -not -name "*.json" 2>/dev/null -exec cat {} \; >> "$output_dir/crawler_urls.txt" || true
            
            if [ -f "$output_dir/crawler_urls.txt" ]; then
                sort -u "$output_dir/crawler_urls.txt" >> "$output_dir/all_urls.txt"
            fi
        fi
        
        log "$domain" "过滤URL..."
        if [ -f "$HOME/tools/pureurls.py" ]; then
            cp "$output_dir/all_urls.txt" "$SCRIPT_DIR/urls.txt"
            run_with_timeout "cd \"$SCRIPT_DIR\" && python3 \"$HOME/tools/pureurls.py\"" 300 "URL过滤" "$domain" true
            
            if [ -f "$SCRIPT_DIR/pureurls.txt" ]; then
                mv "$SCRIPT_DIR/pureurls.txt" "$output_dir/pureurls.txt"
            else
                log "$domain" "URL过滤失败，使用原始URL列表"
                cp "$output_dir/all_urls.txt" "$output_dir/pureurls.txt"
            fi
            rm -f "$SCRIPT_DIR/urls.txt"
        else
            log "$domain" "未找到pureurls.py脚本，使用原始URL列表"
            cp "$output_dir/all_urls.txt" "$output_dir/pureurls.txt"
        fi
        
        if [ ! -s "$output_dir/pureurls.txt" ]; then
            log "$domain" "警告: 未找到有效URL，添加根域名URL"
            echo "https://$domain" > "$output_dir/pureurls.txt"
        fi
        
        create_checkpoint "$domain" "url_processing"
        checkpoint="url_processing"
    fi

    # 步骤 7: 生成最终报告
    if [[ "$checkpoint" == "url_processing" ]]; then
        log "$domain" "阶段 7/7 - 生成报告"
        
        if check_tool "unfurl"; then
            log "$domain" "提取URL参数..."
            cat "$output_dir/pureurls.txt" | unfurl keys | grep -vP '[\/?]' | sort -u > "$output_dir/params.txt"
            
            log "$domain" "提取URL路径..."
            cat "$output_dir/pureurls.txt" | unfurl paths | sed 's/^.//' | sort -u | grep -v -E '\.(jpg|jpeg|gif|css|js|png|ico|woff|svg|pdf)$' > "$output_dir/paths.txt"
        else
            log "$domain" "unfurl工具不可用，跳过参数和路径提取"
            touch "$output_dir/params.txt"
            touch "$output_dir/paths.txt"
        fi
        
        log "$domain" "生成HTML报告..."
        {
            echo "<!DOCTYPE html>"
            echo "<html>"
            echo "<head>"
            echo "  <title>信息收集报告 - $domain</title>"
            echo "  <style>"
            echo "    body { font-family: Arial, sans-serif; margin: 20px; }"
            echo "    h1 { color: #2c3e50; }"
            echo "    h2 { color: #3498db; margin-top: 30px; }"
            echo "    .stats { background: #f8f9fa; padding: 15px; border-radius: 5px; }"
            echo "    table { width: 100%; border-collapse: collapse; margin-top: 10px; }"
            echo "    th, td { padding: 8px; text-align: left; border-bottom: 1px solid #ddd; }"
            echo "    th { background-color: #f2f2f2; }"
            echo "    .url-list { max-height: 400px; overflow-y: auto; }"
            echo "  </style>"
            echo "</head>"
            echo "<body>"
            echo "  <h1>信息收集报告 - $domain</h1>"
            echo "  <p>生成时间: $(date)</p>"
            
            echo "  <div class='stats'>"
            echo "    <h2>统计数据</h2>"
            echo "    <table>"
            echo "      <tr><th>项目</th><th>数量</th></tr>"
            echo "      <tr><td>存活域名</td><td>$(wc -l < "$output_dir/sub_alive.txt" 2>/dev/null || echo 0)</td></tr>"
            echo "      <tr><td>收集的URL</td><td>$(wc -l < "$output_dir/pureurls.txt" 2>/dev/null || echo 0)</td></tr>"
            echo "      <tr><td>唯一参数</td><td>$(wc -l < "$output_dir/params.txt" 2>/dev/null || echo 0)</td></tr>"
            echo "      <tr><td>唯一路径</td><td>$(wc -l < "$output_dir/paths.txt" 2>/dev/null || echo 0)</td></tr>"
            echo "    </table>"
            echo "  </div>"
            
            if [ -s "$output_dir/params.txt" ]; then
                echo "  <h2>发现的URL参数</h2>"
                echo "  <div class='url-list'>"
                echo "    <table>"
                echo "      <tr><th>#</th><th>参数名</th></tr>"
                awk '{print "      <tr><td>" NR "</td><td>" $0 "</td></tr>"}' "$output_dir/params.txt" | head -50
                echo "    </table>"
                echo "    <p><i>显示前50个参数，共$(wc -l < "$output_dir/params.txt")个</i></p>"
                echo "  </div>"
            fi
            
            if [ -s "$output_dir/pureurls.txt" ]; then
                echo "  <h2>部分收集的URL</h2>"
                echo "  <div class='url-list'>"
                echo "    <table>"
                echo "      <tr><th>#</th><th>URL</th></tr>"
                awk '{print "      <tr><td>" NR "</td><td>" $0 "</td></tr>"}' "$output_dir/pureurls.txt" | head -50
                echo "    </table>"
                echo "    <p><i>显示前50个URL，共$(wc -l < "$output_dir/pureurls.txt")个</i></p>"
                echo "  </div>"
            fi
            
            echo "</body>"
            echo "</html>"
        } > "$output_dir/report.html"
        
        log "$domain" "报告已生成: $output_dir/report.html"
        create_checkpoint "$domain" "complete"
    fi

    # 从running移动到completed
    sed -i "/$domain/d" tasks/running_domains.txt
    echo "$domain" >> tasks/completed_domains.txt
    
    log "$domain" "处理流程完成"
    return 0
}

# 主函数
main() {
    echo "信息收集脚本 - 轻量版 - 启动时间: $(date)"
    echo "日志将保存到 logs/master_${DATE_STAMP}.log"
    
    log "系统" "检查必要工具..."
    local missing_tools=()
    for tool in subfinder puredns httpx; do
        if ! check_tool "$tool"; then
            missing_tools+=("$tool")
        fi
    done
    
    if [ ${#missing_tools[@]} -ne 0 ]; then
        log "系统" "警告: 以下核心工具缺失: ${missing_tools[*]}"
        log "系统" "请安装这些工具后再运行脚本"
        exit 1
    fi
    
    init_task_status
    split_domains
    
    log "系统" "开始处理 $(wc -l < tasks/pending_domains.txt) 个域名"
    
    domains=$(cat tasks/pending_domains.txt)
    
    for domain in $domains; do
        process_domain "$domain"
        sleep 5
    done
    
    log "系统" "所有域名处理完成 - 完成时间: $(date)"
    echo "检查 logs/master_${DATE_STAMP}.log 获取详细日志"
}

# 判断是否需要后台运行
if [ "$1" != "--background" ]; then
    nohup bash "$0" --background > "logs/startup_${DATE_STAMP}.log" 2>&1 &
    echo "信息收集任务已在后台启动，进程ID: $!"
    echo "使用 'tail -f logs/master_${DATE_STAMP}.log' 查看进度"
else
    main
fi
