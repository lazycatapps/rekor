# Rekor 服务测试指南

本文档将引导你一步步验证 Rekor 服务的功能是否正常工作。

## 前置条件

确保已安装以下工具：

```bash
# 安装 cosign
go install github.com/sigstore/cosign/v2/cmd/cosign@latest

# 安装 rekor-cli
go install github.com/sigstore/rekor/cmd/rekor-cli@latest
```

## 测试步骤

### 1. 测试服务健康状态

首先验证 Rekor 服务是否正常运行：

```bash

# 获取 Lazycat box 名称
BOXNAME=$(lzc-cli box default)

# 测试健康检查端点
curl -f https://rekor.${BOXNAME}.heiyu.space/ping

# 获取 Rekor 公钥
curl https://rekor.${BOXNAME}.heiyu.space/api/v1/log/publicKey

# 查看日志信息
curl https://rekor.${BOXNAME}.heiyu.space/api/v1/log
```

如果以上命令都返回正常结果，说明服务基本运行正常。

### 2. 准备测试文件和密钥

```bash
# 创建测试文件
echo "test content" > /tmp/test.txt

# 生成 cosign 密钥对（会提示输入密码）
cosign generate-key-pair

# 获取并保存 Rekor 公钥
curl https://rekor.${BOXNAME}.heiyu.space/api/v1/log/publicKey > rekor.pub
```

### 3. 签名并上传到 Rekor

使用 cosign 签名文件并自动上传到 Rekor：

```bash
cosign sign-blob /tmp/test.txt \
  --key cosign.key \
  --output-signature /tmp/test.txt.sig \
  --rekor-url https://rekor.${BOXNAME}.heiyu.space
```

**输出示例：**
```
Using payload from: /tmp/test.txt
Enter password for private key:
tlog entry created with index: 0
Signature wrote in the file /tmp/test.txt.sig
```

记下输出中的 `index` 值和 `tlog entry` UUID（如果显示）。

### 4. 验证签名和透明日志

#### 方法 1：使用 cosign 验证（推荐）

```bash
# 使用环境变量指定 Rekor 公钥
export SIGSTORE_REKOR_PUBLIC_KEY=rekor.pub

cosign verify-blob /tmp/test.txt \
  --key cosign.pub \
  --signature /tmp/test.txt.sig \
  --rekor-url https://rekor.${BOXNAME}.heiyu.space
```

**成功输出：**
```
Verified OK
```

#### 方法 2：使用 rekor-cli 验证

```bash
# 通过 UUID 验证（从签名输出中获取）
rekor-cli verify --rekor_server https://rekor.${BOXNAME}.heiyu.space \
  --uuid <UUID>

# 或通过文件哈希搜索并验证
rekor-cli search --rekor_server https://rekor.${BOXNAME}.heiyu.space \
  --sha $(sha256sum /tmp/test.txt | awk '{print $1}')
```

### 5. 查询和检索条目

```bash
# 查看日志总体信息
rekor-cli loginfo --rekor_server https://rekor.${BOXNAME}.heiyu.space

# 通过 LogIndex 获取条目详情
rekor-cli get --rekor_server https://rekor.${BOXNAME}.heiyu.space \
  --log-index <index>

# 通过文件哈希搜索
rekor-cli search --rekor_server https://rekor.${BOXNAME}.heiyu.space \
  --sha $(sha256sum /tmp/test.txt | awk '{print $1}')
```

## 常见问题

### Q1: 出现 "invalid signature when validating IEEE_P1363 encoded signature" 错误

**原因：** 使用了不兼容的签名工具（如 OpenSSL）。

**解决：** 使用 cosign 进行签名和上传：

```bash
cosign sign-blob /tmp/test.txt \
  --key cosign.key \
  --output-signature /tmp/test.txt.sig \
  --rekor-url https://rekor.${BOXNAME}.heiyu.space
```

### Q2: cosign verify-blob 出现 "rekor log public key not found" 错误

**原因：** 没有提供 Rekor 服务的公钥。

**解决：** 使用环境变量指定公钥文件路径：

```bash
export SIGSTORE_REKOR_PUBLIC_KEY=rekor.pub
```

### Q3: 如何跳过透明日志验证（仅用于测试）

```bash
cosign verify-blob /tmp/test.txt \
  --key cosign.pub \
  --signature /tmp/test.txt.sig \
  --insecure-ignore-tlog
```

**注意：** 生产环境不应跳过透明日志验证。

## 完整测试脚本

```bash
#!/bin/bash
BOXNAME=$(lzc-cli box default)

# 设置 Rekor 服务器地址
REKOR_URL="https://rekor.${BOXNAME}.heiyu.space"

echo "=== 1. 测试服务健康状态 ==="
curl -f $REKOR_URL/ping && echo "✓ Ping 成功"

echo -e "\n=== 2. 获取 Rekor 公钥 ==="
curl $REKOR_URL/api/v1/log/publicKey > rekor.pub && echo "✓ 公钥已保存"

echo -e "\n=== 3. 创建测试文件 ==="
echo "test content" > /tmp/test.txt && echo "✓ 测试文件已创建"

echo -e "\n=== 4. 生成密钥对（如果不存在）==="
if [ ! -f cosign.key ]; then
  cosign generate-key-pair
fi

echo -e "\n=== 5. 签名并上传 ==="
cosign sign-blob /tmp/test.txt \
  --key cosign.key \
  --output-signature /tmp/test.txt.sig \
  --rekor-url $REKOR_URL

echo -e "\n=== 6. 验证签名 ==="
export SIGSTORE_REKOR_PUBLIC_KEY=rekor.pub
cosign verify-blob /tmp/test.txt \
  --key cosign.pub \
  --signature /tmp/test.txt.sig \
  --rekor-url $REKOR_URL

echo -e "\n=== 7. 查看日志信息 ==="
rekor-cli loginfo --rekor_server $REKOR_URL

echo -e "\n✓ 所有测试完成！"
```

## 服务端口说明

- **3000**: Rekor Server 主 API 端口（用于日志条目的创建、查询等）
- **2112**: Prometheus metrics 端点（用于监控和指标收集）

## 参考链接

- [Rekor 官方文档](https://github.com/sigstore/rekor)
- [Cosign 官方文档](https://github.com/sigstore/cosign)
- [Sigstore 项目](https://www.sigstore.dev/)
