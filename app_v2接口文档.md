# App V2 接口文档 (加密通信协议 v2.0)

## 1. 协议概述

App V2 接口采用全量二进制加密通信，旨在通过多层混淆和加密机制，防止流量特征识别、重放攻击和中间人抓包。

### 1.1 通信层级
数据在传输过程中经过以下三层处理：
1.  **应用层 (JSON)**: 原始业务数据。
2.  **加密层 (AES-256-GCM)**: 提供机密性和完整性保护。
3.  **混淆层 (XOR + Reverse)**: 破坏数据结构和长度特征，抗深度包检测 (DPI)。

### 1.2 关键参数

| 参数 | 值 | 说明 |
| :--- | :--- | :--- |
| **AES Key** | `89A7B6C5D4E3F2019876543210ABCDEF1234562890ABCDEF89A7B6C5D4E3F201` | 32字节 (256-bit) Hex 字符串 (需 Hex Decode)。 |
| **AES Algorithm** | AES-256-GCM | 使用 GCM 模式，无需 Padding，自带数据完整性校验 (Tag)。 |
| **AES Nonce** | 12字节随机数 | 每次加密随机生成，拼接到密文头部。 |
| **Obfuscate Key** | `7M8N9B8V7C9X8Z7A9S8D7F9G8H7J9K8L7P9O8I7U9Y8W7T9R8P7M9N8B7V9C8X7Z9A8S7D9F8G7H9J8K7L6P` | 66字节 ASCII 字符串，用于滚动异或。 |

---

## 2. 算法实现细节

### 2.1 混淆算法 (Obfuscate)
**输入**: `Data` (字节数组)
**输出**: `ObfuscatedData` (字节数组)

**步骤**:
1.  **Rolling XOR**: 使用 66 字节 Key 对数据进行滚动异或。
    ```go
    for i, b := range Data {
        Data[i] = b ^ Key[i % 66]
    }
    ```
2.  **Reverse**: 将异或后的字节数组进行**首尾倒序**。
    ```go
    // [0x01, 0x02, 0x03] -> [0x03, 0x02, 0x01]
    for i, j := 0, len(Data)-1; i < j; i, j = i+1, j-1 {
        Data[i], Data[j] = Data[j], Data[i]
    }
    ```

### 2.2 去混淆算法 (Deobfuscate)
**输入**: `ObfuscatedData`
**输出**: `Data`

**步骤**:
1.  **Reverse**: 先将数据倒序还原。
2.  **Rolling XOR**: 再次进行滚动异或 (异或运算是可逆的：`A ^ K ^ K = A`)。

### 2.3 加密流程 (Request)
1.  **JSON**: 将请求参数序列化为 JSON 字符串。
2.  **Encrypt**: 
    - 生成 12 字节随机 `Nonce`。
    - `Ciphertext = AES_GCM_Seal(Key, Nonce, JSON)`。
    - `EncryptedData = Nonce + Ciphertext`。
3.  **Obfuscate**: 调用混淆算法处理 `EncryptedData`。
4.  **Send**: 将结果作为 HTTP Body 发送 (`Content-Type: application/octet-stream`)。

### 2.4 解密流程 (Response)
1.  **Receive**: 读取 HTTP Response Body。
2.  **Deobfuscate**: 调用去混淆算法还原 `EncryptedData`。
3.  **Decrypt**:
    - 提取前 12 字节作为 `Nonce`。
    - 剩余部分作为 `Ciphertext`。
    - `JSON = AES_GCM_Open(Key, Nonce, Ciphertext)`。
4.  **Parse**: 解析 JSON 数据。

### 2.5 错误处理
所有接口响应（包括 HTTP 200 业务成功、业务失败、以及 HTTP 4xx/5xx 系统错误）**均通过二进制加密流返回**。
客户端必须始终按照 **解密流程** 处理 Response Body。解密后的 JSON `code` 字段用于区分成功或失败。

- `code = 200`: 成功。
- `code != 200`: 失败，`msg` 字段包含错误信息。

---

## 3. 接口定义

### 3.1 设备登录/注册

- **URL**: `/app/v2/login`
- **Method**: `POST`
- **Content-Type**: `application/octet-stream`

#### 请求参数 (Decrypted JSON)

| 字段名 | 类型 | 必填 | 说明 | 示例 |
| :--- | :--- | :--- | :--- | :--- |
| device_id | string | 是 | 设备唯一硬件标识符 | `android_id_123456789` |

**原始 JSON 示例**:
```json
{
    "device_id": "android_id_123456789"
}
```

#### 返回参数 (Decrypted JSON)

| 字段名 | 类型 | 说明 |
| :--- | :--- | :--- |
| code | int | 业务状态码 (200: 成功) |
| msg | string | 提示信息 |
| data | object | 业务数据 |
| - id | int | 用户 ID |
| - dpid | int | 用户 dpid |
| - uuid | string | 用户 UUID |
| - email | string | 自动生成的邮箱 (`{device_id}@qq.com`) |
| - status | int | 账号状态 (1: 正常) |
| - quota | int64 | 剩余可用流量 (字节) |
| - token | string | 接口访问凭证 (Bearer Token) |
| - code | string | 邀请码 |
| - subscribe_url | string | **完整订阅地址** (用于获取节点配置) |
| - expire_time | string | 过期时间 (RFC3339) |

**原始 JSON 示例**:
```json
{
    "code": 200,
    "msg": "Login Success",
    "data": {
        "id": 1001,
        "dpid": 2001,
        "uuid": "550e8400-e29b-41d4-a716-446655440000",
        "email": "android_id_123456789@qq.com",
        "status": 1,
        "quota": 5368709120,
        "token": "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...",
        "code": "A1B2C3D4",
        "subscribe_url": "https://api.vpn.com/s/A1B2C3D4",
        "expire_time": "2025-12-31T23:59:59+08:00"
    }
}
```

#### 错误响应 (Decrypted JSON)
> 注意：错误响应同样是经过 **混淆和加密** 的二进制流。客户端解密后可得到如下 JSON。

```json
{
    "code": 400,
    "msg": "Validation Error: DeviceID required",
    "data": null
}
```

### 3.2 获取用户实时信息 (流量/过期时间)

- **URL**: `/app/v2/user/info`
- **Method**: `GET`
- **Content-Type**: `application/octet-stream`
- **Auth**: Required (Bearer Token in Header)

**注意**: 此接口同样遵循 **二进制加密通信协议**。请求体虽为空（GET 请求），但响应体仍是加密混淆的二进制流。

#### 请求参数
无 (通过 Header 中的 Authorization 传递 Token)

#### 返回参数 (Decrypted JSON)

| 字段名 | 类型 | 说明 |
| :--- | :--- | :--- |
| code | int | 业务状态码 (200: 成功, 404: 缓存不存在需重新登录) |
| msg | string | 提示信息 |
| data | object | 业务数据 |
| - quota | int64 | 剩余可用流量 (字节) |
| - expire_time | string | 过期时间 (RFC3339) |

**说明**: 
- 此接口直接从 Redis 读取最新缓存数据，**不查询 MySQL**。
- 若 Redis 中无数据（缓存过期或未登录），将返回 404 错误，客户端应引导用户重新调用登录接口。
- 流量计算公式：`Available = TransferEnable - (U + D)`。

**原始 JSON 示例**:
```json
{
    "code": 200,
    "msg": "Success",
    "data": {
        "quota": 5368709120,
        "expire_time": "2025-12-31T23:59:59+08:00"
    }
}
```

### 3.3 提交订单

- **URL**: `/app/v2/order/save`
- **Method**: `POST`
- **Content-Type**: `application/octet-stream`
- **Auth**: Required (Bearer Token in Header)

#### 请求参数 (Decrypted JSON)

| 字段名 | 类型 | 必填 | 说明 | 示例 |
| :--- | :--- | :--- | :--- | :--- |
| item | string | 是 | 套餐标识，对应 `node_item.label` | `500GB` |

**原始 JSON 示例**:
```json
{
    "item": "500GB"
}
```

#### 业务处理规则

1. 先判断当前登录用户 `dp_id` 是否等于 `-1`，若是则返回 `code=101`。
2. 校验 `item` 是否存在于 `node_item` 表 `label` 字段，不存在返回“套餐不存在”。
3. 校验通过后创建订单，返回订单号 `order_no`。

#### 返回参数 (Decrypted JSON)

| 字段名 | 类型 | 说明 |
| :--- | :--- | :--- |
| code | int | 业务状态码 |
| msg | string | 提示信息 |
| data | string/null | 成功时为订单号 `order_no`，失败时为 `null` |

**成功响应示例**:
```json
{
    "code": 200,
    "msg": "订单创建成功",
    "data": "202603151742301234"
}
```

**失败响应示例 (dp_id = -1)**:
```json
{
    "code": 101,
    "msg": "dp_id无效",
    "data": null
}
```

**失败响应示例 (套餐不存在)**:
```json
{
    "code": 400,
    "msg": "套餐不存在",
    "data": null
}
```

### 3.4 提交卡密

- **URL**: `/app/v2/user/invite`
- **Method**: `POST`
- **Content-Type**: `application/octet-stream`
- **Auth**: Required (Bearer Token in Header)

#### 请求参数 (Decrypted JSON)

| 字段名 | 类型 | 必填 | 说明 | 示例 |
| :--- | :--- | :--- | :--- | :--- |
| invite | string | 是 | 卡密，对应 `admins.username` | `5oYSIxw0` |

**原始 JSON 示例**:
```json
{
    "invite": "5oYSIxw0"
}
```

#### 业务处理规则

1. 判断 `invite` 是否提交，未提交返回“invite不能为空”。
2. 根据 `invite` 查询 `admins.username`，不存在返回“invite不存在”。
3. 将当前登录用户在 `users` 表中的 `dp_id` 更新为查询到的 `admins.id`。
4. 返回成功。

#### 返回参数 (Decrypted JSON)

| 字段名 | 类型 | 说明 |
| :--- | :--- | :--- |
| code | int | 业务状态码 |
| msg | string | 提示信息 |
| data | null | 固定为 `null` |

**成功响应示例**:
```json
{
    "code": 200,
    "msg": "成功",
    "data": null
}
```

**失败响应示例 (invite 为空)**:
```json
{
    "code": 400,
    "msg": "invite不能为空",
    "data": null
}
```

**失败响应示例 (invite 不存在)**:
```json
{
    "code": 400,
    "msg": "invite不存在",
    "data": null
}
```

### 3.5 获取支付列表

- **URL**: `/app/v2/pay/list`
- **Method**: `GET`
- **Content-Type**: `application/octet-stream`
- **Auth**: Required (Bearer Token in Header)

#### 请求参数
无 (通过 Header 中的 Authorization 传递 Token)

#### 业务处理规则

1. 查询 `pays` 表中 `status=1` 的记录。
2. 仅返回 `id`、`name` 字段。

#### 返回参数 (Decrypted JSON)

| 字段名 | 类型 | 说明 |
| :--- | :--- | :--- |
| code | int | 业务状态码 |
| msg | string | 提示信息 |
| data | array | 支付方式列表 |
| - id | int | 支付方式 ID |
| - name | string | 支付方式名称 |

**成功响应示例**:
```json
{
    "code": 200,
    "msg": "获取成功",
    "data": [
        {
            "id": 1,
            "name": "支付宝"
        },
        {
            "id": 2,
            "name": "微信支付"
        }
    ]
}
```

### 3.6 订单发起支付

- **URL**: `/app/v2/order/checkout`
- **Method**: `POST`
- **Content-Type**: `application/octet-stream`
- **Auth**: Required (Bearer Token in Header)

#### 请求参数 (Decrypted JSON)

| 字段名 | 类型 | 必填 | 说明 | 示例 |
| :--- | :--- | :--- | :--- | :--- |
| method | string | 是 | 支付通道ID | `37` |
| trade_no | string | 是 | 订单号 | `2026031517735881879315` |

**原始 JSON 示例**:
```json
{
    "method": "37",
    "trade_no": "2026031517735881879315"
}
```

#### 业务处理规则

1. 判断 `method` 是否提交，未提交返回“method不能为空”。
2. 判断 `trade_no` 是否提交，未提交返回“trade_no不能为空”。
3. 业务处理参考 `/app/v1/user/order/checkout`：校验支付通道与订单归属，创建支付并返回支付地址。

#### 返回参数 (Decrypted JSON)

| 字段名 | 类型 | 说明 |
| :--- | :--- | :--- |
| code | int | 业务状态码 |
| msg | string | 提示信息 |
| data | string/null | 成功时为支付地址，失败时为 `null` |

**成功响应示例**:
```json
{
    "code": 200,
    "msg": "Checkout initiated",
    "data": "https://pay.example.com/xxx"
}
```

**失败响应示例 (method 为空)**:
```json
{
    "code": 400,
    "msg": "method不能为空",
    "data": null
}
```

**失败响应示例 (trade_no 为空)**:
```json
{
    "code": 400,
    "msg": "trade_no不能为空",
    "data": null
}
```

### 3.7 查询订单状态

- **URL**: `/app/v2/order/detail`
- **Method**: `GET`
- **Content-Type**: `application/octet-stream`
- **Auth**: Required (Bearer Token in Header)

#### 请求参数 (Query)

| 字段名 | 类型 | 必填 | 说明 | 示例 |
| :--- | :--- | :--- | :--- | :--- |
| trade_no | string | 是 | 订单号 | `2026031517735881879315` |

#### 业务处理规则

1. 判断 `trade_no` 是否提交，未提交返回“trade_no不能为空”。
2. 业务处理参考 `/app/v1/user/order/detail`，按当前登录用户 + 订单号查询订单。
3. 返回该订单号对应的 `status`。

#### 返回参数 (Decrypted JSON)

| 字段名 | 类型 | 说明 |
| :--- | :--- | :--- |
| code | int | 业务状态码 |
| msg | string | 提示信息 |
| data | object/null | 成功时包含订单状态 |
| - status | int | 订单状态 |

**成功响应示例**:
```json
{
    "code": 200,
    "msg": "查询成功",
    "data": {
        "status": 1
    }
}
```

**失败响应示例 (trade_no 为空)**:
```json
{
    "code": 400,
    "msg": "trade_no不能为空",
    "data": null
}
```
