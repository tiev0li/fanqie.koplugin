-- FanQie APP source cryptography (ported from the Legado/阅读 book source
-- "番茄小说(APP)"). Pure Lua (LuaJIT `bit`). All byte strings are Lua strings.
--
-- Provides: base64, md5(re-export), sm3, sha512, AES-CBC (128/192/256,
-- NoPadding/PKCS7), the custom ARGUS 64-bit-block cipher, the custom Ladon
-- cipher, 2048-bit Diffie-Hellman (BigInt modPow via Barrett reduction),
-- gzip (stored DEFLATE blocks) and the ttEnc device-registration envelope.

local ok_bit, bit = pcall(require, "bit")
if not ok_bit or not bit then
    error("fanqie.appcrypto requires the LuaJIT `bit` library")
end
local band, bor, bxor, bnot = bit.band, bit.bor, bit.bxor, bit.bnot
local lshift, rshift, rol32 = bit.lshift, bit.rshift, bit.rol

local Crypto = require("fanqie.crypto") -- md5_hex

local unpack = unpack or table.unpack
local floor, ceil = math.floor, math.ceil
local char, byte, rep, sub, concat = string.char, string.byte, string.rep, string.sub, table.concat
local format = string.format

local AC = {}

-- Normalize a LuaJIT bit result (signed int32) to an unsigned double [0, 2^32).
local function norm(x)
    x = band(x, 0xffffffff)
    if x < 0 then x = x + 4294967296 end
    return x
end

-- ===========================================================================
-- Hex / Base64
-- ===========================================================================

local function hex(s)
    return (s:gsub(".", function(c) return format("%02x", byte(c)) end))
end

local function unhex(h)
    local out = {}
    for i = 1, #h, 2 do
        out[#out + 1] = char(tonumber(sub(h, i, i + 1), 16))
    end
    return concat(out)
end

local B64C = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
local B64I = {}
for i = 1, 64 do B64I[sub(B64C, i, i)] = i - 1 end

local function b64e(s)
    local out = {}
    for i = 1, #s, 3 do
        local a = byte(s, i)
        local b = byte(s, i + 1)
        local c = byte(s, i + 2)
        local n = a * 65536 + (b or 0) * 256 + (c or 0)
        local e1 = rshift(n, 18)
        local e2 = band(rshift(n, 12), 63)
        local e3 = b and band(rshift(n, 6), 63) or 64
        local e4 = c and band(n, 63) or 64
        out[#out + 1] = sub(B64C, e1 + 1, e1 + 1) .. sub(B64C, e2 + 1, e2 + 1)
            .. (e3 == 64 and "=" or sub(B64C, e3 + 1, e3 + 1))
            .. (e4 == 64 and "=" or sub(B64C, e4 + 1, e4 + 1))
    end
    return concat(out)
end

local function b64d(s)
    local out = {}
    local buf, bits = 0, 0
    for i = 1, #s do
        local ch = sub(s, i, i)
        if ch == "=" then break end
        local v = B64I[ch]
        if v then
            buf = band(buf * 64 + v, 0xffffffff)
            bits = bits + 6
            if bits >= 8 then
                bits = bits - 8
                out[#out + 1] = char(band(rshift(buf, bits), 0xff))
            end
        end
    end
    return concat(out)
end

AC.hex, AC.unhex, AC.b64e, AC.b64d = hex, unhex, b64e, b64d
AC.md5_hex = Crypto.md5_hex

-- ===========================================================================
-- CRC32 (for gzip)
-- ===========================================================================

local CRC_T = {}
for n = 0, 255 do
    local c = n
    for _ = 1, 8 do
        if band(c, 1) == 1 then c = bxor(0xedb88320, rshift(c, 1)) else c = rshift(c, 1) end
    end
    CRC_T[n] = c
end

local function crc32(s)
    local c = 0xffffffff
    for i = 1, #s do
        c = bxor(CRC_T[band(bxor(c, byte(s, i)), 0xff)], rshift(c, 8))
    end
    return norm(bxor(c, 0xffffffff))
end
AC.crc32 = crc32

local function le32(x)
    return char(band(x, 0xff), band(rshift(x, 8), 0xff), band(rshift(x, 16), 0xff), band(rshift(x, 24), 0xff))
end

-- gzip container with STORED (uncompressed) DEFLATE blocks — no libz needed.
local function gzip_stored(s)
    local parts = { '\031\139\008\000\000\000\000\000\002\003' }
    local n = #s
    local pos = 1
    while true do
        local chunk = math.min(65535, n - pos + 1)
        if chunk < 0 then chunk = 0 end
        local last = (pos + chunk - 1) >= n
        local bfinal = last and 1 or 0
        local nlen = band(bxor(chunk, 0xffff), 0xffff)
        parts[#parts + 1] = char(bfinal, band(chunk, 0xff), band(rshift(chunk, 8), 0xff),
            band(nlen, 0xff), band(rshift(nlen, 8), 0xff))
        if chunk > 0 then parts[#parts + 1] = sub(s, pos, pos + chunk - 1) end
        pos = pos + chunk
        if last then break end
    end
    parts[#parts + 1] = le32(crc32(s)) .. le32(n % 4294967296)
    return concat(parts)
end
AC.gzip_stored = gzip_stored

-- ===========================================================================
-- PKCS7 padding
-- ===========================================================================

local function pkcs7_pad(s)
    local p = 16 - (#s % 16)
    if p == 0 then p = 16 end
    return s .. rep(char(p), p)
end

local function pkcs7_unpad(s)
    if #s == 0 then return s end
    local p = byte(s, #s)
    if not p or p < 1 or p > 16 then return s end
    return sub(s, 1, #s - p)
end
AC.pkcs7_pad, AC.pkcs7_unpad = pkcs7_pad, pkcs7_unpad

-- ===========================================================================
-- SM3 (returns lowercase hex)
-- ===========================================================================

local function sm3(s)
    local function rotl(x, n) n = band(n, 31); return norm(bor(lshift(x, n), rshift(x, 32 - n))) end
    local len = #s
    local bit_len = len * 8
    local arr = {}
    for i = 1, len do arr[#arr + 1] = byte(s, i) end
    arr[#arr + 1] = 0x80
    while #arr % 64 ~= 56 do arr[#arr + 1] = 0 end
    local hi = floor(bit_len / 4294967296)
    local lo = bit_len % 4294967296
    local function push32be(v)
        v = v % 4294967296
        arr[#arr + 1] = band(rshift(v, 24), 0xff)
        arr[#arr + 1] = band(rshift(v, 16), 0xff)
        arr[#arr + 1] = band(rshift(v, 8), 0xff)
        arr[#arr + 1] = band(v, 0xff)
    end
    push32be(hi); push32be(lo)

    local V = { 0x7380166f, 0x4914b2b9, 0x172442d7, 0xda8a0600, 0xa96f30bc, 0x163138aa, 0xe38dee4d, 0xb0fb0e4e }
    local function u(x) return band(x, 0xffffffff) end
    for b = 0, #arr - 1, 64 do
        local W = {}
        for i = 0, 15 do
            local o = b + i * 4
            W[i] = norm(bor(lshift(arr[o + 1], 24), lshift(arr[o + 2], 16), lshift(arr[o + 3], 8), arr[o + 4]))
        end
        for j = 16, 67 do
            local x = norm(bxor(W[j - 16], W[j - 9], rotl(W[j - 3], 15)))
            x = norm(bxor(x, rotl(x, 15), rotl(x, 23)))
            W[j] = norm(bxor(x, rotl(W[j - 13], 7), W[j - 6]))
        end
        local W1 = {}
        for j = 0, 63 do W1[j] = norm(bxor(W[j], W[j + 4])) end
        local A, B, C, D = V[1], V[2], V[3], V[4]
        local E, F, G, H = V[5], V[6], V[7], V[8]
        for j = 0, 63 do
            local Tj = (j < 16) and 0x79cc4519 or 0x7a879d8a
            local SS1 = rotl(u(rotl(A, 12) + E + rotl(Tj, band(j, 31))), 7)
            local SS2 = norm(bxor(SS1, rotl(A, 12)))
            local FFj = (j < 16) and norm(bxor(A, B, C)) or norm(bor(band(A, B), band(A, C), band(B, C)))
            local GGj = (j < 16) and norm(bxor(E, F, G)) or norm(bor(band(E, F), band(bnot(E), G)))
            local TT1 = u(FFj + D + SS2 + W1[j])
            local TT2 = u(GGj + H + SS1 + W[j])
            D = C; C = rotl(B, 9); B = A; A = TT1
            H = G; G = rotl(F, 19); F = E; E = norm(bxor(TT2, rotl(TT2, 9), rotl(TT2, 17)))
        end
        V[1] = norm(bxor(V[1], A)); V[2] = norm(bxor(V[2], B))
        V[3] = norm(bxor(V[3], C)); V[4] = norm(bxor(V[4], D))
        V[5] = norm(bxor(V[5], E)); V[6] = norm(bxor(V[6], F))
        V[7] = norm(bxor(V[7], G)); V[8] = norm(bxor(V[8], H))
    end
    local out = {}
    for i = 1, 8 do
        local v = V[i]
        if v < 0 then v = v + 4294967296 end
        out[#out + 1] = format("%08x", v)
    end
    return concat(out)
end
AC.sm3 = sm3

-- ===========================================================================
-- SHA-512 (returns raw 64-byte string). 64-bit words as {hi, lo} u32 pairs.
-- ===========================================================================

-- 64-bit constants stored as hex strings (Lua doubles can't hold >53 bits
-- exactly). Split into {hi, lo} u32 pairs at load time.
local SHA512_K_HEX = {
    "428a2f98d728ae22", "7137449123ef65cd", "b5c0fbcfec4d3b2f", "e9b5dba58189dbbc",
    "3956c25bf348b538", "59f111f1b605d019", "923f82a4af194f9b", "ab1c5ed5da6d8118",
    "d807aa98a3030242", "12835b0145706fbe", "243185be4ee4b28c", "550c7dc3d5ffb4e2",
    "72be5d74f27b896f", "80deb1fe3b1696b1", "9bdc06a725c71235", "c19bf174cf692694",
    "e49b69c19ef14ad2", "efbe4786384f25e3", "0fc19dc68b8cd5b5", "240ca1cc77ac9c65",
    "2de92c6f592b0275", "4a7484aa6ea6e483", "5cb0a9dcbd41fbd4", "76f988da831153b5",
    "983e5152ee66dfab", "a831c66d2db43210", "b00327c898fb213f", "bf597fc7beef0ee4",
    "c6e00bf33da88fc2", "d5a79147930aa725", "06ca6351e003826f", "142929670a0e6e70",
    "27b70a8546d22ffc", "2e1b21385c26c926", "4d2c6dfc5ac42aed", "53380d139d95b3df",
    "650a73548baf63de", "766a0abb3c77b2a8", "81c2c92e47edaee6", "92722c851482353b",
    "a2bfe8a14cf10364", "a81a664bbc423001", "c24b8b70d0f89791", "c76c51a30654be30",
    "d192e819d6ef5218", "d69906245565a910", "f40e35855771202a", "106aa07032bbd1b8",
    "19a4c116b8d2d0c8", "1e376c085141ab53", "2748774cdf8eeb99", "34b0bcb5e19b48a8",
    "391c0cb3c5c95a63", "4ed8aa4ae3418acb", "5b9cca4f7763e373", "682e6ff3d6b2b8a3",
    "748f82ee5defb2fc", "78a5636f43172f60", "84c87814a1f0ab72", "8cc702081a6439ec",
    "90befffa23631e28", "a4506cebde82bde9", "bef9a3f7b2c67915", "c67178f2e372532b",
    "ca273eceea26619c", "d186b8c721c0c207", "eada7dd6cde0eb1e", "f57d4f7fee6ed178",
    "06f067aa72176fba", "0a637dc5a2c898a6", "113f9804bef90dae", "1b710b35131c471b",
    "28db77f523047d84", "32caab7b40c72493", "3c9ebe0a15c9bebc", "431d67c49c100d4c",
    "4cc5d4becb3e42b6", "597f299cfc657e2a", "5fcb6fab3ad6faec", "6c44198c4a475817",
}

local function h64_from_hex(h)
    return { hi = tonumber(h:sub(1, 8), 16), lo = tonumber(h:sub(9, 16), 16) }
end

local K = {}
for i = 1, 80 do K[i] = h64_from_hex(SHA512_K_HEX[i]) end

local SHA512_H0_HEX = {
    "6a09e667f3bcc908", "bb67ae8584caa73b", "3c6ef372fe94f82b", "a54ff53a5f1d36f1",
    "510e527fade682d1", "9b05688c2b3e6c1f", "1f83d9abfb41bd6b", "5be0cd19137e2179",
}

local function h64(hi, lo) return { hi = hi, lo = lo } end
local function xor64(a, b) return h64(norm(bxor(a.hi, b.hi)), norm(bxor(a.lo, b.lo))) end
local function and64(a, b) return h64(norm(band(a.hi, b.hi)), norm(band(a.lo, b.lo))) end
local function not64(a) return h64(norm(bnot(a.hi)), norm(bnot(a.lo))) end

local function add64(...)
    local hi, lo = 0, 0
    for i = 1, select('#', ...) do
        local v = select(i, ...)
        lo = lo + v.lo
        local carry = 0
        if lo >= 4294967296 then lo = lo - 4294967296; carry = 1 end
        hi = (hi + v.hi + carry) % 4294967296
    end
    return h64(hi, lo)
end

local function rotr64(a, n)
    if n < 32 then
        return h64(norm(bor(rshift(a.hi, n), lshift(a.lo, 32 - n))),
                   norm(bor(rshift(a.lo, n), lshift(a.hi, 32 - n))))
    elseif n == 32 then
        return h64(a.lo, a.hi)
    else
        local m = n - 32
        return h64(norm(bor(rshift(a.lo, m), lshift(a.hi, 32 - m))),
                   norm(bor(rshift(a.hi, m), lshift(a.lo, 32 - m))))
    end
end

local function shr64(a, n)
    if n < 32 then
        return h64(norm(rshift(a.hi, n)),
                   norm(bor(rshift(a.lo, n), lshift(a.hi, 32 - n))))
    elseif n == 32 then
        return h64(0, a.hi)
    else
        return h64(0, norm(rshift(a.hi, n - 32)))
    end
end

local function sha512(msg)
    local len = #msg
    local bit_len_hi = floor(len * 8 / 4294967296)
    local bit_len_lo = (len * 8) % 4294967296
    -- pad
    local bytes = {}
    for i = 1, len do bytes[i] = byte(msg, i) end
    bytes[#bytes + 1] = 0x80
    while #bytes % 128 ~= 112 do bytes[#bytes + 1] = 0 end
    -- 128-bit big-endian bit length (top 64 bits = 0, then bit_len hi/lo)
    for _ = 1, 8 do bytes[#bytes + 1] = 0 end
    bytes[#bytes + 1] = band(rshift(bit_len_hi, 24), 0xff)
    bytes[#bytes + 1] = band(rshift(bit_len_hi, 16), 0xff)
    bytes[#bytes + 1] = band(rshift(bit_len_hi, 8), 0xff)
    bytes[#bytes + 1] = band(bit_len_hi, 0xff)
    bytes[#bytes + 1] = band(rshift(bit_len_lo, 24), 0xff)
    bytes[#bytes + 1] = band(rshift(bit_len_lo, 16), 0xff)
    bytes[#bytes + 1] = band(rshift(bit_len_lo, 8), 0xff)
    bytes[#bytes + 1] = band(bit_len_lo, 0xff)

    local H = {}
    for i = 1, 8 do H[i] = h64_from_hex(SHA512_H0_HEX[i]) end

    local W = {}
    for b = 0, #bytes - 1, 128 do
        for t = 0, 15 do
            local o = b + t * 8
            local hi = bor(lshift(bytes[o + 1], 24), lshift(bytes[o + 2], 16), lshift(bytes[o + 3], 8), bytes[o + 4])
            local lo = bor(lshift(bytes[o + 5], 24), lshift(bytes[o + 6], 16), lshift(bytes[o + 7], 8), bytes[o + 8])
            W[t] = h64(norm(hi), norm(lo))
        end
        for t = 16, 79 do
            local s0 = xor64(xor64(rotr64(W[t - 15], 1), rotr64(W[t - 15], 8)), shr64(W[t - 15], 7))
            local s1 = xor64(xor64(rotr64(W[t - 2], 19), rotr64(W[t - 2], 61)), shr64(W[t - 2], 6))
            W[t] = add64(W[t - 16], s0, W[t - 7], s1)
        end
        local a, b, c, d, e, f, g, h = H[1], H[2], H[3], H[4], H[5], H[6], H[7], H[8]
        for t = 0, 79 do
            local S1 = xor64(xor64(rotr64(e, 14), rotr64(e, 18)), rotr64(e, 41))
            local ch = xor64(and64(e, f), and64(not64(e), g))
            local t1 = add64(h, S1, ch, K[t + 1], W[t])
            local S0 = xor64(xor64(rotr64(a, 28), rotr64(a, 34)), rotr64(a, 39))
            local maj = xor64(xor64(and64(a, b), and64(a, c)), and64(b, c))
            local t2 = add64(S0, maj)
            h = g; g = f; f = e; e = add64(d, t1)
            d = c; c = b; b = a; a = add64(t1, t2)
        end
        H[1] = add64(H[1], a); H[2] = add64(H[2], b); H[3] = add64(H[3], c); H[4] = add64(H[4], d)
        H[5] = add64(H[5], e); H[6] = add64(H[6], f); H[7] = add64(H[7], g); H[8] = add64(H[8], h)
    end

    local out = {}
    local function be32(x)
        return char(band(rshift(x, 24), 0xff), band(rshift(x, 16), 0xff), band(rshift(x, 8), 0xff), band(x, 0xff))
    end
    for i = 1, 8 do
        out[#out + 1] = be32(norm(H[i].hi)) .. be32(norm(H[i].lo))
    end
    return concat(out)
end
AC.sha512 = sha512

-- ===========================================================================
-- AES (128/192/256) block cipher + CBC
-- ===========================================================================

local function gf_mul(a, b)
    local p = 0
    a = band(a, 0xff); b = band(b, 0xff)
    for _ = 1, 8 do
        if band(b, 1) == 1 then p = bxor(p, a) end
        local hi = band(a, 0x80)
        a = band(lshift(a, 1), 0xff)
        if hi ~= 0 then a = bxor(a, 0x1b) end
        b = rshift(b, 1)
    end
    return p
end

local SBOX, INV_SBOX = {}, {}
do
    local function rotl8(x, n) return band(bor(lshift(x, n), rshift(x, 8 - n)), 0xff) end
    local function gf_inv(x)
        if x == 0 then return 0 end
        local result, base, e = 1, x, 254
        while e > 0 do
            if band(e, 1) == 1 then result = gf_mul(result, base) end
            base = gf_mul(base, base)
            e = rshift(e, 1)
        end
        return result
    end
    for i = 0, 255 do
        local inv = gf_inv(i)
        local s = band(bxor(inv, rotl8(inv, 1), rotl8(inv, 2), rotl8(inv, 3), rotl8(inv, 4), 0x63), 0xff)
        SBOX[i] = s
        INV_SBOX[s] = i
    end
end

-- Precompute GF multiplication tables for the constants used in MixColumns.
local M2, M3, M9, M11, M13, M14 = {}, {}, {}, {}, {}, {}
for i = 0, 255 do
    M2[i] = gf_mul(i, 2); M3[i] = gf_mul(i, 3); M9[i] = gf_mul(i, 9)
    M11[i] = gf_mul(i, 11); M13[i] = gf_mul(i, 13); M14[i] = gf_mul(i, 14)
end

local RCON = { 0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x1b, 0x36, 0x6c, 0xd8, 0xab, 0x4d }

local function aes_key_expand(key)
    local nk = #key / 4
    local nr = nk + 6
    local words = {}
    for i = 0, nk - 1 do
        words[i] = { byte(key, 4 * i + 1), byte(key, 4 * i + 2), byte(key, 4 * i + 3), byte(key, 4 * i + 4) }
    end
    for i = nk, 4 * (nr + 1) - 1 do
        local temp = { words[i - 1][1], words[i - 1][2], words[i - 1][3], words[i - 1][4] }
        if i % nk == 0 then
            temp = { temp[2], temp[3], temp[4], temp[1] } -- RotWord
            for j = 1, 4 do temp[j] = SBOX[temp[j]] end   -- SubWord
            temp[1] = bxor(temp[1], RCON[i / nk])
        elseif nk > 6 and i % nk == 4 then
            for j = 1, 4 do temp[j] = SBOX[temp[j]] end
        end
        words[i] = { bxor(words[i - nk][1], temp[1]), bxor(words[i - nk][2], temp[2]),
                     bxor(words[i - nk][3], temp[3]), bxor(words[i - nk][4], temp[4]) }
    end
    local rk = {}
    for i = 0, 4 * (nr + 1) - 1 do
        for j = 1, 4 do rk[#rk + 1] = words[i][j] end
    end
    return rk, nr
end

local function shift_rows(st)
    local t = { unpack(st) }
    for r = 0, 3 do
        for c = 0, 3 do
            st[c * 4 + r + 1] = t[((c + r) % 4) * 4 + r + 1]
        end
    end
end

local function inv_shift_rows(st)
    local t = { unpack(st) }
    for r = 0, 3 do
        for c = 0, 3 do
            st[c * 4 + r + 1] = t[((c - r) % 4) * 4 + r + 1]
        end
    end
end

local function mix_columns(st)
    for c = 0, 3 do
        local i = c * 4 + 1
        local a0, a1, a2, a3 = st[i], st[i + 1], st[i + 2], st[i + 3]
        st[i]     = bxor(M2[a0], M3[a1], a2, a3)
        st[i + 1] = bxor(a0, M2[a1], M3[a2], a3)
        st[i + 2] = bxor(a0, a1, M2[a2], M3[a3])
        st[i + 3] = bxor(M3[a0], a1, a2, M2[a3])
    end
end

local function inv_mix_columns(st)
    for c = 0, 3 do
        local i = c * 4 + 1
        local a0, a1, a2, a3 = st[i], st[i + 1], st[i + 2], st[i + 3]
        st[i]     = bxor(M14[a0], M11[a1], M13[a2], M9[a3])
        st[i + 1] = bxor(M9[a0], M14[a1], M11[a2], M13[a3])
        st[i + 2] = bxor(M13[a0], M9[a1], M14[a2], M11[a3])
        st[i + 3] = bxor(M11[a0], M13[a1], M9[a2], M14[a3])
    end
end

local function sub_bytes(st) for i = 1, 16 do st[i] = SBOX[st[i]] end end
local function inv_sub_bytes(st) for i = 1, 16 do st[i] = INV_SBOX[st[i]] end end

local function aes_encrypt_block(inp, rk, nr)
    local st = {}
    for i = 1, 16 do st[i] = bxor(inp[i], rk[i]) end
    for round = 1, nr - 1 do
        sub_bytes(st); shift_rows(st); mix_columns(st)
        local base = round * 16
        for i = 1, 16 do st[i] = bxor(st[i], rk[base + i]) end
    end
    sub_bytes(st); shift_rows(st)
    local base = nr * 16
    for i = 1, 16 do st[i] = bxor(st[i], rk[base + i]) end
    return st
end

local function aes_decrypt_block(inp, rk, nr)
    local st = {}
    for i = 1, 16 do st[i] = bxor(inp[i], rk[nr * 16 + i]) end
    for round = nr - 1, 1, -1 do
        inv_shift_rows(st); inv_sub_bytes(st)
        local base = round * 16
        for i = 1, 16 do st[i] = bxor(st[i], rk[base + i]) end
        inv_mix_columns(st)
    end
    inv_shift_rows(st); inv_sub_bytes(st)
    for i = 1, 16 do st[i] = bxor(st[i], rk[i]) end
    return st
end

local function bytes_to_str(t)
    local n = #t
    local parts = {}
    local i = 1
    while i <= n do
        local j = math.min(i + 4095, n)
        parts[#parts + 1] = char(unpack(t, i, j))
        i = j + 1
    end
    return concat(parts)
end

local function str_to_block(s, o)
    local b = {}
    for i = 0, 15 do b[i + 1] = byte(s, o + i) end
    return b
end

-- padding: "none" (input must be block-aligned) or "pkcs7".
local function aes_cbc_encrypt(data, key, iv, padding)
    if padding == "pkcs7" then data = pkcs7_pad(data) end
    if #data % 16 ~= 0 then error("aes_cbc_encrypt: data not block aligned") end
    local rk, nr = aes_key_expand(key)
    local prev = str_to_block(iv, 1)
    local out = {}
    for o = 1, #data, 16 do
        local blk = str_to_block(data, o)
        for i = 1, 16 do blk[i] = bxor(blk[i], prev[i]) end
        local enc = aes_encrypt_block(blk, rk, nr)
        prev = enc
        for i = 1, 16 do out[#out + 1] = enc[i] end
    end
    return bytes_to_str(out)
end

local function aes_cbc_decrypt(data, key, iv, padding)
    if #data % 16 ~= 0 then error("aes_cbc_decrypt: data not block aligned") end
    local rk, nr = aes_key_expand(key)
    local prev = str_to_block(iv, 1)
    local out = {}
    for o = 1, #data, 16 do
        local blk = str_to_block(data, o)
        local dec = aes_decrypt_block(blk, rk, nr)
        for i = 1, 16 do out[#out + 1] = bxor(dec[i], prev[i]) end
        prev = blk
    end
    local res = bytes_to_str(out)
    if padding == "pkcs7" then res = pkcs7_unpad(res) end
    return res
end

AC.aes_cbc_encrypt = aes_cbc_encrypt
AC.aes_cbc_decrypt = aes_cbc_decrypt

-- ===========================================================================
-- Secure-ish random bytes
-- ===========================================================================

do
    local seed = os.time() + floor((os.clock() or 0) * 1000)
    pcall(math.randomseed, seed)
    pcall(math.random) -- warm up
end

local function random_bytes(n)
    local f = io.open("/dev/urandom", "rb")
    if f then
        local d = f:read(n)
        f:close()
        if d and #d == n then return d end
    end
    local t = {}
    for i = 1, n do t[i] = math.random(0, 255) end
    return char(unpack(t))
end
AC.random_bytes = random_bytes

-- ===========================================================================
-- BigInt (base 2^24 limbs, little-endian) + Barrett modular exponentiation
-- ===========================================================================

local BI_BASE = 16777216 -- 2^24
local BI_BITS = 24
local BI_HEX = 6         -- hex digits per limb

local function bi_trim(a)
    local n = #a
    while n > 0 and a[n] == 0 do a[n] = nil; n = n - 1 end
    return a
end

local function bi_from_hex(h)
    h = h:gsub("^0+", "")
    if h == "" then return {} end
    local limbs = {}
    local i = #h
    while i > 0 do
        local j = math.max(1, i - (BI_HEX - 1))
        limbs[#limbs + 1] = tonumber(sub(h, j, i), 16)
        i = j - 1
    end
    return bi_trim(limbs)
end

local function bi_to_hex(a)
    if #a == 0 then return "0" end
    local parts = { format("%x", a[#a]) }
    for i = #a - 1, 1, -1 do parts[#parts + 1] = format("%06x", a[i]) end
    return concat(parts)
end

local function bi_cmp(a, b)
    if #a ~= #b then return #a < #b and -1 or 1 end
    for i = #a, 1, -1 do
        if a[i] ~= b[i] then return a[i] < b[i] and -1 or 1 end
    end
    return 0
end

local function bi_add(a, b)
    local n = math.max(#a, #b)
    local res, carry = {}, 0
    for i = 1, n do
        local s = (a[i] or 0) + (b[i] or 0) + carry
        if s >= BI_BASE then s = s - BI_BASE; carry = 1 else carry = 0 end
        res[i] = s
    end
    if carry > 0 then res[n + 1] = carry end
    return bi_trim(res)
end

local function bi_sub(a, b) -- requires a >= b
    local res, borrow = {}, 0
    for i = 1, #a do
        local s = (a[i] or 0) - (b[i] or 0) - borrow
        if s < 0 then s = s + BI_BASE; borrow = 1 else borrow = 0 end
        res[i] = s
    end
    return bi_trim(res)
end

local function bi_mul(a, b)
    if #a == 0 or #b == 0 then return {} end
    local res = {}
    for i = 1, #a + #b do res[i] = 0 end
    for i = 1, #a do
        local ai = a[i]
        local carry = 0
        for j = 1, #b do
            local idx = i + j - 1
            local cur = res[idx] + ai * b[j] + carry
            res[idx] = cur % BI_BASE
            carry = floor(cur / BI_BASE)
        end
        res[i + #b] = res[i + #b] + carry
    end
    return bi_trim(res)
end

local function bi_bit_length(a)
    if #a == 0 then return 0 end
    local top = a[#a]
    local bits = (#a - 1) * BI_BITS
    while top > 0 do bits = bits + 1; top = floor(top / 2) end
    return bits
end

local function bi_test_bit(a, i)
    local limb = a[floor(i / BI_BITS) + 1]
    if not limb then return false end
    return band(rshift(limb, i % BI_BITS), 1) == 1
end

local function bi_set_bit(a, i)
    local idx = floor(i / BI_BITS) + 1
    while #a < idx do a[#a + 1] = 0 end
    a[idx] = bor(a[idx], lshift(1, i % BI_BITS))
end

local function bi_shl1(a)
    local res, carry = {}, 0
    for i = 1, #a do
        local v = a[i] * 2 + carry
        if v >= BI_BASE then v = v - BI_BASE; carry = 1 else carry = 0 end
        res[i] = v
    end
    if carry > 0 then res[#res + 1] = carry end
    return res
end

local function bi_shr_limbs(a, k)
    local res = {}
    for i = k + 1, #a do res[#res + 1] = a[i] end
    return bi_trim(res)
end

local function bi_low_limbs(a, k)
    local res = {}
    for i = 1, math.min(k, #a) do res[i] = a[i] end
    return bi_trim(res)
end

-- Schoolbook long division (bit-by-bit); used once per session to build mu.
local function bi_divmod(u, v)
    if bi_cmp(u, v) < 0 then return {}, u end
    local q = {}
    local r = {}
    local nbits = bi_bit_length(u)
    for i = nbits - 1, 0, -1 do
        r = bi_shl1(r)
        if bi_test_bit(u, i) then r = bi_add(r, { 1 }) end
        if bi_cmp(r, v) >= 0 then
            r = bi_sub(r, v)
            bi_set_bit(q, i)
        end
    end
    return bi_trim(q), bi_trim(r)
end

local barrett_cache = {}
local function bi_barrett_ctx(m)
    local key = bi_to_hex(m)
    local ctx = barrett_cache[key]
    if ctx then return ctx end
    local k = #m
    local num = {}
    for i = 1, 2 * k do num[i] = 0 end
    num[2 * k + 1] = 1 -- B^(2k)
    local mu = bi_divmod(num, m)
    ctx = { m = m, k = k, mu = mu }
    barrett_cache[key] = ctx
    return ctx
end

local function bi_barrett_reduce(ctx, x)
    local m, k, mu = ctx.m, ctx.k, ctx.mu
    if bi_cmp(x, m) < 0 then return x end
    local q1 = bi_shr_limbs(x, k - 1)
    local q2 = bi_mul(q1, mu)
    local q3 = bi_shr_limbs(q2, k + 1)
    local r1 = bi_low_limbs(x, k + 1)
    local r2 = bi_low_limbs(bi_mul(q3, m), k + 1)
    local r
    if bi_cmp(r1, r2) < 0 then
        local bpk1 = {}
        for i = 1, k + 1 do bpk1[i] = 0 end
        bpk1[k + 2] = 1 -- B^(k+1)
        r = bi_sub(bi_add(r1, bpk1), r2)
    else
        r = bi_sub(r1, r2)
    end
    while bi_cmp(r, m) >= 0 do r = bi_sub(r, m) end
    return r
end

local function bi_modpow(base, exp, m)
    local ctx = bi_barrett_ctx(m)
    base = bi_barrett_reduce(ctx, base)
    local result = { 1 }
    local b = base
    local nbits = bi_bit_length(exp)
    for i = 0, nbits - 1 do
        if bi_test_bit(exp, i) then
            result = bi_barrett_reduce(ctx, bi_mul(result, b))
        end
        b = bi_barrett_reduce(ctx, bi_mul(b, b))
    end
    return result
end

AC.bigint = {
    from_hex = bi_from_hex, to_hex = bi_to_hex, modpow = bi_modpow,
    cmp = bi_cmp, add = bi_add, sub = bi_sub, mul = bi_mul,
}

-- ===========================================================================
-- ARGUS cipher (custom 64-bit block cipher) — words as {lo, hi} u32 pairs.
-- ===========================================================================

local FQ_SK = 'fc78e0a9657a0c748ce51559903ccf03510e51d3cff232d71343e88a321c5304'
local FQ_AK = 'd31e3718288a1027baab59f146a09a9c'
local FQ_AIV = 'ea180a0336ed352fcd24e4d50018ae54'
local FQ_FIXED = 'TdTC5rgxYgkOUrPHpnM7pByyRiuCmrWKGWs521cXdST0m69/COjWjSanLjfBqVovHwWlGJKu8pSXMrYqOKrdWA=='

local function w(lo, hi) return { lo = norm(lo), hi = norm(hi) } end

local function wxor(...)
    local lo, hi = 0, 0
    for i = 1, select('#', ...) do
        local v = select(i, ...)
        lo = bxor(lo, v.lo)
        hi = bxor(hi, v.hi)
    end
    return w(lo, hi)
end

local function wnot(v) return w(bnot(v.lo), bnot(v.hi)) end

local function wadd(a, b)
    local lo = a.lo + b.lo
    local carry = 0
    if lo >= 4294967296 then lo = lo - 4294967296; carry = 1 end
    local hi = (a.hi + b.hi + carry) % 4294967296
    return w(lo, hi)
end

local function wrol(v, c)
    local s = c % 64
    if s == 0 then return w(v.lo, v.hi) end
    if s < 32 then
        return w(bor(lshift(v.lo, s), rshift(v.hi, 32 - s)),
                 bor(lshift(v.hi, s), rshift(v.lo, 32 - s)))
    end
    if s == 32 then return w(v.hi, v.lo) end
    local r = s - 32
    return w(bor(lshift(v.hi, r), rshift(v.lo, 32 - r)),
             bor(lshift(v.lo, r), rshift(v.hi, 32 - r)))
end

local function wror(v, c) return wrol(v, 64 - (c % 64)) end

local function r64(s, o)
    o = o or 0
    local lo = byte(s, o + 1) + byte(s, o + 2) * 256 + byte(s, o + 3) * 65536 + byte(s, o + 4) * 16777216
    local hi = byte(s, o + 5) + byte(s, o + 6) * 256 + byte(s, o + 7) * 65536 + byte(s, o + 8) * 16777216
    return w(lo, hi)
end

local function le4(x)
    return char(band(x, 0xff), band(rshift(x, 8), 0xff), band(rshift(x, 16), 0xff), band(rshift(x, 24), 0xff))
end

local function w64le2(l, r)
    return le4(l.lo) .. le4(l.hi) .. le4(r.lo) .. le4(r.hi)
end

local SZ_LO, SZ_HI = 0x046d678b, 0x3dc94c3a
local function zbit(i)
    local b
    if i < 32 then b = band(rshift(SZ_LO, i), 1) else b = band(rshift(SZ_HI, i - 32), 1) end
    return w(b, 0)
end

local function srk(key) -- key: 32-byte string -> 72 round words (0-based)
    local wds = {}
    for i = 0, 3 do wds[i] = r64(key, i * 8) end
    for x = 4, 71 do
        local m = wxor(wror(wds[x - 1], 3), wds[x - 3])
        m = wxor(m, wror(m, 1))
        wds[x] = wxor(wnot(wds[x - 4]), m, zbit((x - 4) % 62), w(3, 0))
    end
    return wds
end

local function sEnc(blk, keys) -- blk: 16-byte string
    local l = r64(blk, 0)
    local r = r64(blk, 8)
    for i = 0, 71 do
        local o = r
        local r1 = wrol(r, 1)
        local r8 = wrol(r, 8)
        local nl = w(band(r1.lo, r8.lo), band(r1.hi, r8.hi))
        r = wxor(l, nl, wrol(r, 2), keys[i])
        l = o
    end
    return w64le2(l, r)
end

-- varint / protobuf-ish encoders
local function ev(v)
    local out = {}
    while v >= 0x80 do
        out[#out + 1] = char(bor(v % 0x80, 0x80))
        v = floor(v / 0x80)
    end
    out[#out + 1] = char(v)
    return concat(out)
end

local function pbv(f, v) return ev(f * 8) .. ev(v) end

local function pbb(f, v)
    local e = (type(v) == "number") and char(v) or tostring(v)
    return ev(f * 8 + 2) .. ev(#e) .. e
end

-- Query-string / URL parameter helpers (faithful to the JS: the *second*
-- FQ_qp declaration wins, which parses from a URL's query string. Since the
-- query passed in has no '?', the version_name field resolves to "").
local function qs_of(url)
    local t = tostring(url or "")
    local i = t:find("?", 1, true)
    if not i then return "" end
    local j = t:find("#", i + 1, true)
    return sub(t, i + 1, j and (j - 1) or #t)
end

local function qp(url, name)
    local ps = {}
    for part in qs_of(url):gmatch("[^&]+") do ps[#ps + 1] = part end
    for _, p in ipairs(ps) do
        local s = p:find("=", 1, true)
        local k = s and sub(p, 1, s - 1) or p
        if k == name then return s and sub(p, s + 1) or "" end
    end
    return ""
end
AC.qs_of = qs_of

local function argus_bean(q, stub, ts, dev, iid, aid, rv)
    local bi
    -- Lua patterns have no {n} quantifier: check length explicitly.
    if type(stub) == "string" and #stub == 32 and stub:match("^%x+$") then
        bi = unhex(stub)
    else
        bi = unhex("00000000000000000000000000000000")
    end
    local bh = unhex(sub(sm3(bi), 1, 12))
    local qh
    if q == "" then
        qh = unhex(sub(sm3(unhex("00000000000000000000000000000000")), 1, 12))
    else
        qh = unhex(sub(sm3(q), 1, 12))
    end
    local nest = pbv(1, 1) .. pbv(2, 1) .. pbv(3, 1) .. pbv(7, 0xC792ECCC)
    local s23 = pbb(1, "NX551J") .. pbv(2, 8196) .. pbv(4, 0x80E0D800)
    return pbv(1, 1077940818) .. pbv(2, 2) .. pbv(3, rv) .. pbb(4, tostring(aid))
        .. pbb(5, dev) .. pbb(6, "1611921764") .. pbb(7, qp(q, "version_name"))
        .. pbb(8, "v04.04.05-ov-android") .. pbv(9, 134744640)
        .. pbb(10, unhex("0000000000000000")) .. pbv(11, 0) .. pbv(12, ts * 2)
        .. pbb(13, bh) .. pbb(14, qh) .. pbb(15, nest) .. pbb(16, iid)
        .. pbb(20, "none") .. pbv(21, 738) .. pbb(23, s23) .. pbv(25, 2)
end

local function argus(q, stub, ts, dev, iid, aid, rv)
    local pb = pkcs7_pad(argus_bean(q, stub, ts, dev, iid, aid, rv))
    local keys = srk(unhex(FQ_SK))
    local enc = {}
    for o = 1, #pb, 16 do
        enc[#enc + 1] = sEnc(sub(pb, o, o + 15), keys)
    end
    local magic = unhex("f2f7fcfff2f7fcff")
    local un = magic .. concat(enc) .. unhex("eafb2cfe8568519154")
    local buf = { sub(un, 1, 8) }
    for i = 9, #un do
        buf[#buf + 1] = char(bxor(byte(un, i), byte(magic, ((i - 1) % 8) + 1)))
    end
    local rev = concat(buf):reverse()
    local fin = pkcs7_pad(rev .. "ao")
    local ct = aes_cbc_encrypt(fin, unhex(FQ_AK), unhex(FQ_AIV), "none")
    return b64e(unhex("f281") .. ct)
end

-- ===========================================================================
-- Ladon cipher
-- ===========================================================================

local function lrk(rp, aid)
    local dg = Crypto.md5_hex(rp .. tostring(aid)) -- 32-char hex string
    local wds = {}
    for i = 0, 34 do wds[i] = w(0, 0) end
    wds[0] = r64(dg, 0); wds[1] = r64(dg, 8); wds[2] = r64(dg, 16); wds[3] = r64(dg, 24)
    local b0, b8 = wds[0], wds[1]
    local q = { wds[2], wds[3] }
    for x = 0, 0x21 do
        local x9 = b0
        local x8 = b8
        x8 = wror(x8, 8)
        x8 = wadd(x8, x9)
        x8 = wxor(x8, w(x, 0))
        q[#q + 1] = x8
        x8 = wxor(x8, wrol(x9, 3))
        wds[x + 1] = x8
        b0 = x8
        b8 = table.remove(q, 1)
    end
    return wds
end

local function lEnc(blk, keys)
    local l = r64(blk, 0)
    local r = r64(blk, 8)
    for i = 0, 33 do
        r = wxor(keys[i], wadd(l, wror(r, 8)))
        l = wxor(r, wror(l, 61))
    end
    return w64le2(l, r)
end

local function ladon(ts, lic, aid, rp)
    local data = tostring(ts) .. "-" .. tostring(lic) .. "-" .. tostring(aid)
    local pd = pkcs7_pad(data)
    local ks = lrk(rp, aid)
    local ct = {}
    for o = 1, #pd, 16 do
        ct[#ct + 1] = lEnc(sub(pd, o, o + 15), ks)
    end
    return b64e(rp .. concat(ct))
end

-- ===========================================================================
-- Sign / ttEnc
-- ===========================================================================

local function sign(q, stub, ts, dev, iid, aid, rv)
    local h = {
        ["x-ss-req-ticket"] = format("%.0f", ts * 1000),
        ["x-khronos"] = tostring(ts),
        ["x-argus"] = argus(q, stub, ts, dev, iid, aid, rv),
        ["x-ladon"] = ladon(ts, 1611921764, aid, char(1, 2, 3, 4)),
    }
    if stub and stub ~= "" then h["x-ss-stub"] = stub end
    return h
end

local function ttenc(data)
    local rnd = random_bytes(32)
    local inner = sha512(rnd)
    local hv = sha512(inner .. b64d(FQ_FIXED))
    local key = sub(hv, 1, 16)
    local iv = sub(hv, 17, 32)
    local dh = sha512(data)
    local plain = pkcs7_pad(dh .. data)
    local ct = aes_cbc_encrypt(plain, key, iv, "none")
    return char(0x74, 0x63, 0x05, 0x10, 0, 0) .. rnd .. ct
end

AC.argus, AC.ladon, AC.sign, AC.ttenc = argus, ladon, sign, ttenc
AC.argus_bean = argus_bean

-- ===========================================================================
-- CM Diffie-Hellman channel
-- ===========================================================================

local CMP = 'ffffffffffffffffc90fdaa22168c234c4c6628b80dc1cd129024e088a67cc74020bbea63b139b22514a08798e3404ddef9519b3cd3a431b302b0a6df25f14374fe1356d6d51c245e485b576625e7ec6f44c42e9a637ed6b0bff5cb6f406b7edee386bfb5a899fa5ae9f24117c4b1fe649286651ece45b3dc2007cb8a163bf0598da48361c55d39a69163fa8fd24cf5f83655d23dca3ad961c62f356208552bb9ed529077096966d670c354e4abc9804f1746c08ca237327ffffffffffffffff'
local P_BI = nil
local function get_P()
    if not P_BI then P_BI = bi_from_hex(CMP) end
    return P_BI
end

local function big_bytes(n_bi)
    local h = bi_to_hex(n_bi)
    if #h % 2 == 1 then h = "0" .. h end
    if #h > 384 then h = sub(h, #h - 383) end -- keep last 384 hex chars
    return unhex(h)
end

local function bi_random_bits(nbits)
    local nbytes = ceil(nbits / 8)
    return bi_from_hex(hex(random_bytes(nbytes)))
end

-- Returns (key_b64, pk). `key_b64` goes into the mget request body; `pk` is
-- the client private key needed later to decrypt the response.
local function cm_make_key()
    local P = get_P()
    local pk = bi_random_bits(256)
    local pub = bi_modpow({ 2 }, pk, P)
    local iv = random_bytes(16)
    local rk = b64d('rCXGfd2POMGzeiNIgo4iLg==')
    local ct1 = aes_cbc_encrypt(big_bytes(pub), rk, iv, "pkcs7")
    return b64e(iv .. ct1), pk
end

-- Decrypt one item's content. Returns the plaintext (string, may be JSON).
local function cm_decrypt(pk, srv_key_b64, content_b64)
    local P = get_P()
    local srv_bi = bi_from_hex(hex(b64d(srv_key_b64)))
    local shared = bi_modpow(srv_bi, pk, P)
    local sh_hex = bi_to_hex(shared)
    if #sh_hex % 2 == 1 then sh_hex = "0" .. sh_hex end
    if #sh_hex > 384 then sh_hex = sub(sh_hex, #sh_hex - 383) end
    local aes_key = sub(unhex(sub(sh_hex, 1, 64)), 1, 32)
    local cb = b64d(content_b64)
    local iv = sub(cb, 1, 16)
    local ct = sub(cb, 17)
    return aes_cbc_decrypt(ct, aes_key, iv, "pkcs7")
end

AC.cm_make_key = cm_make_key
AC.cm_decrypt = cm_decrypt

return AC
