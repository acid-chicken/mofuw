#[
  Import Section
]#

import
  critbits, strtabs, parseutils, openssl, osproc, net, nativesockets, asyncdispatch

import mofuhttputils, mofuparser

from httpcore import HttpHeaders

when defined(windows):
  from winlean import TCP_NODELAY, WSAEWOULDBLOCK
else:
  from posix import TCP_NODELAY, EAGAIN, EWOULDBLOCK

  when defined(linux):
    from posix import Pid
    const TCP_FASTOPEN = 23.cint

when defined ssl:
  import os
  export openssl
  export net.SslCVerifyMode

  when not declared(SSL_set_SSL_CTX):
    proc SSL_set_SSL_CTX*(ssl: SslPtr, ctx: SslCtx): SslCtx
      {.cdecl, dynlib: DLLSSLName, importc.}

  var sslCtxTable {.global.}: CritBitTree[SslCtx]

#[
  Type define
]#

type
  MofuwCtx* = ref object
    fd*: AsyncFD
    mhr*: MPHTTPReq
    mc*: MPChunk
    ip*: string
    buf*, resp*: string
    respLen*: int
    bodyStart*: int
    bodyParams*, uriParams*, uriQuerys*: StringTableRef
    # this is for big request
    # TODO
    tmp*: cstring
    when defined ssl:
      isSSL*: bool
      sslCtx*: SslCtx
      sslHandle*: SslPtr

  Callback* = proc(ctx: MofuwCtx): Future[void]

#[
  default using value
]#
const
  kByte = 1024
  mByte = 1024 * kByte

  defaultHeaderLineSize* {.intdefine.} = 8 * kByte
  defaultMaxBodySize* {.intdefine.} = 1 * mByte
  bufSize* {.intdefine.} = 512

var callback {.threadvar.}: Callback
var serverPort {.threadvar.}: int
var maxBodySize {.threadvar.}: int

when defined vhost:
  var callbackTable {.global, threadvar.}: CritBitTree[Callback]

  proc registerCallback*(serverName: string, cb: Callback) =
    callbackTable[serverName] = cb

  proc setCallBackTable*(tbl: CritBitTree[Callback]) =
    callBackTable = tbl

  proc getCallBackTable*: CritBitTree[Callback] =
    return callBackTable

#[
  Proc section
]#

# ##
# sysconf(3) does not respect the affinity mask bits, it's not suitable for containers.
# ##
proc countCPUs*: int =
  when defined(linux):
    const
      schedh = "#define _GNU_SOURCE\n#include <sched.h>"
    type CpuSet {.importc: "cpu_set_t", header: schedh.} = object
      when defined(linux) and defined(amd64):
        abi: array[1024 div (8 * sizeof(culong)), culong]
    var set: CpuSet
    proc sched_getAffinity(pid: Pid, cpusetsize: int, mask: var CpuSet): cint {.
      importc: "sched_getaffinity", header: schedh.}
    proc cpusetCount(s: var CpuSet): int {. importc: "CPU_COUNT", header: schedh.}
    if sched_getAffinity(0, sizeof(CpuSet), set) == 0.cint:
      return cpusetCount(set)
    else:
      return countProcessors()
  else:
    return countProcessors()

# ##
# From man 2 listen, SOMAXCONN is just limit which is hardcoded value 128.
# ##
proc defaultBacklog*: int =
  when defined(linux):
    proc fscanf(c: File, frmt: cstring): cint {.varargs, importc, header: "<stdio.h>".}

    var
      backlog: int = SOMAXCONN
      f: File
      tmp: int

    if f.open("/proc/sys/net/core/somaxconn"): # See `man 2 listen`.
      if fscanf(f, "%d", tmp.addr) == cint(1):
        backlog = tmp
      f.close
    return backlog
  else:
    return SOMAXCONN

proc newServerSocket*(port: int = 8080): SocketHandle =
  let server = newSocket()
  server.setSockOpt(OptReuseAddr, true)
  server.setSockOpt(OptReusePort, true)
  server.getFD().setSockOptInt(cint(IPPROTO_TCP), TCP_NODELAY, 1)
  when defined(linux):
    server.getFD().setSockOptInt(cint(IPPROTO_TCP), TCP_FASTOPEN, 256)
  server.getFd.setBlocking(false)
  server.bindAddr(Port(port))
  server.listen(defaultBacklog().cint)
  return server.getFd()

proc newMofuwCtx*(fd: AsyncFD, ip: string): MofuwCtx =
  result = MofuwCtx(
    fd: fd,
    ip: ip,
    buf: "",
    resp: "",
    mhr: MPHTTPReq()
  )

# ##
# For SSL
# ##
when defined ssl:
  # Let'sEncrypt's default cipher
  const strongCipher = 
    "ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:ECDHE-ECDSA-AES128-GCM-SHA256:" &
    "ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:" &
    "DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-AES128-SHA256:" &
    "ECDHE-RSA-AES128-SHA256:ECDHE-ECDSA-AES128-SHA:ECDHE-RSA-AES256-SHA384:" & 
    "ECDHE-RSA-AES128-SHA:ECDHE-ECDSA-AES256-SHA384:ECDHE-ECDSA-AES256-SHA:" &
    "ECDHE-RSA-AES256-SHA:DHE-RSA-AES128-SHA256:DHE-RSA-AES128-SHA:DHE-RSA-AES256-SHA256:" &
    "DHE-RSA-AES256-SHA:ECDHE-ECDSA-DES-CBC3-SHA:ECDHE-RSA-DES-CBC3-SHA:EDH-RSA-DES-CBC3-SHA:" & 
    "AES128-GCM-SHA256:AES256-GCM-SHA384:AES128-SHA256:AES256-SHA256:AES128-SHA:AES256-SHA:DES-CBC3-SHA:!DSS"

  var sslCipher {.global.}: string
  var sslCert, sslKey {.global.}: string
  var sslCtx* {.global.}: SslCtx

  SSL_library_init()

  # ##
  # From net module
  # ##
  proc loadCertificates(ctx: SSL_CTX, certFile, keyFile: string) =
    if certFile != "" and (not existsFile(certFile)):
      raise newException(system.IOError, "Certificate file could not be found: " & certFile)
    if keyFile != "" and (not existsFile(keyFile)):
      raise newException(system.IOError, "Key file could not be found: " & keyFile)

    if certFile != "":
      var ret = SSLCTXUseCertificateChainFile(ctx, certFile)
      if ret != 1:
        raiseSSLError()

    if keyFile != "":
      if SSL_CTX_use_PrivateKey_file(ctx, keyFile,
                                    SSL_FILETYPE_PEM) != 1:
        raiseSSLError()

      if SSL_CTX_check_private_key(ctx) != 1:
        raiseSSLError("Verification of private key file failed.")

  # ##
  # From net module
  # Edited by @2vg
  # ##
  proc newSSLContext(cert, key: string, mode = CVerifyNone): SslCtx =
    var newCtx: SslCtx
    newCTX = SSL_CTX_new(TLS_method())

    let cipher = 
      if sslCipher != nil or sslCipher != "": sslCipher
      else: strongCipher

    if newCTX.SSLCTXSetCipherList(cipher) != 1:
      raiseSSLError()
    case mode
    of CVerifyPeer:
      newCTX.SSLCTXSetVerify(SSLVerifyPeer, nil)
    of CVerifyNone:
      newCTX.SSLCTXSetVerify(SSLVerifyNone, nil)
    if newCTX == nil:
      raiseSSLError()

    discard newCTX.SSLCTXSetMode(SSL_MODE_AUTO_RETRY)

    newCTX.loadCertificates(cert, key)

    return newCtx

  proc serverNameCallback(ssl: SslPtr, cb_id: int, arg: pointer): int {.cdecl.} =
    if ssl.isNil: return SSL_TLSEXT_ERR_NOACK
    let serverName = SSL_get_servername(ssl)
    if sslCtxTable.hasKey($serverName):
      let newCtx = sslCtxTable[$serverName]
      discard ssl.SSL_set_SSL_CTX(newCtx)
    return SSL_TLSEXT_ERR_OK

  # ##
  # normal fd to sslFD and accept
  # ##
  proc toSSLSocket*(ctx: MofuwCtx) =
    ctx.sslHandle = SSLNew(sslCtx)
    discard SSL_set_fd(ctx.sslHandle, ctx.fd.SocketHandle)
    discard SSL_accept(ctx.sslHandle)

  proc asyncSSLRecv*(ctx: MofuwCtx, buf: ptr char, bufLen: int): Future[int] =
    var retFuture = newFuture[int]("asyncSSLRecv")
    proc cb(fd: AsyncFD): bool =
      result = true
      let rcv = SSL_read(ctx.sslHandle, buf, bufLen.cint)
      if rcv <= 0:
        retFuture.complete(0)
      else:
        retFuture.complete(rcv)
    addRead(ctx.fd, cb)
    return retFuture

  proc asyncSSLSend*(ctx: MofuwCtx, buf: ptr char, bufLen: int): Future[int] =
    var retFuture = newFuture[int]("asyncSSLSend")
    proc cb(fd: AsyncFD): bool =
      result = true
      let rcv = SSL_write(ctx.sslHandle, buf, bufLen.cint)
      if rcv <= 0:
        retFuture.complete(0)
      else:
        retFuture.complete(rcv)
    addWrite(ctx.fd, cb)
    return retFuture

  proc newMofuwCtxSSL*(fd: AsyncFD, ip: string, isSSL: bool): MofuwCtx =
    result = newMofuwCtx(fd, ip)
    result.isSSL = isSSL

  proc addCertAndKey*(cert, key: string, serverName = "", verify = false) =
    let ctx =
      if verify: newSSLContext(cert, key, CVerifyPeer)
      else: newSSLContext(cert, key)

    if sslCtxTable.hasKey(serverName):
      raise newException(Exception, "already have callback.")

    sslCtxTable[serverName] = ctx

    if sslCert.isNil: sslCert = cert
    if sslKey.isNil: sslKey = key
    if sslCtx.isNil: sslCtx = ctx

    discard ctx.SSL_CTX_set_tlsext_servername_callback(serverNameCallback)

  proc setChiper*(ci: string) =
    sslCipher = ci

  proc mofuwSSLInit*(verify: SslCVerifyMode) =
    sslCtx = newSSLContext(sslCert, sslKey, verify)

proc setCallback*(cb: Callback) =
  callback = cb

proc getCallback*: Callback =
  callback

proc setPort*(port: int) =
  serverPort = port

proc setMaxBodySize*(size: int) =
  maxBodySize = size

proc getMaxBodySize*: int =
  maxBodySize

proc getMethod*(ctx: MofuwCtx): string {.inline.} =
  result = getMethod(ctx.mhr)

proc getPath*(ctx: MofuwCtx): string {.inline.} =
  result = getPath(ctx.mhr)

proc getCookie*(ctx: MofuwCtx): string {.inline.} =
  result = getHeader(ctx.mhr, "Cookie")

proc getHeader*(ctx: MofuwCtx, name: string): string {.inline.} =
  result = getHeader(ctx.mhr, name)

proc toHttpHeaders*(ctx: MofuwCtx): HttpHeaders {.inline.} =
  result = ctx.mhr.toHttpHeaders()

proc setParam*(ctx: MofuwCtx, params: StringTableRef) {.inline.} =
  ctx.uriParams = params

proc setQuery*(ctx: MofuwCtx, query: StringTableRef) {.inline.} =
  ctx.uriQuerys = query

proc params*(ctx: MofuwCtx, key: string): string =
  if ctx.uriParams.isNil: return nil
  ctx.uriParams.getOrDefault(key)

proc query*(ctx: MofuwCtx, key: string): string =
  if ctx.uriQuerys.isNil: return nil
  ctx.uriQuerys.getOrDefault(key)

proc bodyParse*(query: string):StringTableRef {.inline.} =
  result = {:}.newStringTable
  var i = 0
  while i < query.len()-1:
    var key = ""
    var val = ""
    i += query.parseUntil(key, '=', i)
    if query[i] != '=':
      raise newException(ValueError, "Expected '=' at " & $i &
                         " but got: " & $query[i])
    inc(i) # Skip =
    i += query.parseUntil(val, '&', i)
    inc(i) # Skip &
    result[key] = val

# ##
# get body
# req.body -> all body
# req.body("user") -> get body query "user"
# ##
proc body*(ctx: MofuwCtx, key: string = nil): string =
  if key.isNil: return $ctx.buf[ctx.bodyStart .. ^1]
  if ctx.bodyParams.isNil: ctx.bodyParams = ctx.body.bodyParse
  ctx.bodyParams.getOrDefault(key)