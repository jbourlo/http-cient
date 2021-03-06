;;;
;;; Convenient HTTP client library
;;;
;; Copyright (c) 2008-2016, Peter Bex
;; Parts copyright (c) 2000-2004, Felix L. Winkelmann
;; All rights reserved.
;;
;; Redistribution and use in source and binary forms, with or without
;; modification, are permitted provided that the following conditions
;; are met:
;;
;; 1. Redistributions of source code must retain the above copyright
;;    notice, this list of conditions and the following disclaimer.
;; 2. Redistributions in binary form must reproduce the above
;;    copyright notice, this list of conditions and the following
;;    disclaimer in the documentation and/or other materials provided
;;    with the distribution.
;; 3. Neither the name of the author nor the names of its
;;    contributors may be used to endorse or promote products derived
;;    from this software without specific prior written permission.
;;
;; THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
;; "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
;; LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS
;; FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE
;; COPYRIGHT HOLDERS OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT,
;; INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
;; (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
;; SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
;; HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT,
;; STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
;; ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED
;; OF THE POSSIBILITY OF SUCH DAMAGE.
;
(module http-client
  (max-retry-attempts max-redirect-depth retry-request? client-software
   close-connection! close-all-connections!
   call-with-input-request call-with-input-request*
   with-input-from-request call-with-response
   store-cookie! delete-cookie! get-cookies-for-uri
   http-authenticators get-username/password
   basic-authenticator digest-authenticator
   determine-username/password determine-proxy
   determine-proxy-from-environment determine-proxy-username/password
   server-connector default-server-connector)

(import chicken scheme lolevel)
(use srfi-1 srfi-13 srfi-18 srfi-69
     ports files extras tcp data-structures posix
     intarweb uri-common message-digest md5 string-utils sendfile)

;; Major TODOs:
;; * Find a better approach for storing cookies and server connections,
;;    which will scale to applications with hundreds of connections
;; * Implement md5-sess handling for digest auth
;; * Use nonce count in digest auth (is this even needed? I think it's only
;;    needed if there are webservers out there that send the same nonce
;;    repeatedly. This client doesn't do request pipelining so we don't
;;    generate requests with the same nonce if the server doesn't)
;; * Find a way to do automated testing to increase robustness & reliability
;; * Test and document SSL support
;; * The authenticators stuff is really really ugly.  It's intentionally
;;    undocumented so nobody is going to rely on it too much yet, and
;;    we have the freedom to change it later.

(define-record http-connection base-uri inport outport proxy)

(define max-retry-attempts (make-parameter 1))
(define max-redirect-depth (make-parameter 5))

(define retry-request? (make-parameter idempotent?))

(define (determine-proxy-from-environment uri)
  (let* ((is-cgi-process (get-environment-variable "REQUEST_METHOD"))
         ;; If we're running in a CGI script, don't use HTTP_PROXY, to
         ;; avoid a "httpoxy" attack.  Instead, we use the variable
         ;; CGI_HTTP_PROXY.  See https://httpoxy.org
         (proxy-variable
          (if (and (eq? (uri-scheme uri) 'http) is-cgi-process)
              "cgi_http_proxy"
              (conc (uri-scheme uri) "_proxy")))
         (no-proxy (or (get-environment-variable "no_proxy")
                       (get-environment-variable "NO_PROXY")))
         (no-proxy (and no-proxy (map (lambda (s)
                                        (string-split s ":"))
                                      (string-split no-proxy ","))))
         (host-excluded? (lambda (entry)
                           (let ((host (car entry))
                                 (port (and (pair? (cdr entry))
                                            (string->number (cadr entry)))))
                             (and (or (string=? host "*")
                                      (string-ci=? host (uri-host uri)))
                                  (or (not port)
                                      (= (uri-port uri) port)))))))
    (cond
     ((and no-proxy (any host-excluded? no-proxy)) #f)
     ((or (get-environment-variable proxy-variable)
          (get-environment-variable (string-upcase proxy-variable))
          (get-environment-variable "all_proxy")
          (get-environment-variable "ALL_PROXY")) =>
          (lambda (proxy)               ; TODO: make this just absolute-uri
            (and-let* ((proxy-uri (uri-reference proxy))
                       ((absolute-uri? proxy-uri)))
              proxy-uri)))
     (else #f))))

(define determine-proxy (make-parameter determine-proxy-from-environment))

(define determine-proxy-username/password
  (make-parameter (lambda (uri realm)
                    (values (uri-username uri) (uri-password uri)))))

;; Maybe only pass uri and realm to this?
(define determine-username/password
  (make-parameter (lambda (uri realm)
                    (values (uri-username uri) (uri-password uri)))))

(define client-software
  (make-parameter (list (list "CHICKEN Scheme HTTP-client" "0.10" #f))))

;; TODO: find a smarter storage mechanism
(define cookie-jar (list))

(define connections
  (make-parameter (make-hash-table
                   (lambda (a b)
                     (and (equal? (uri-port a) (uri-port b))
                          (equal? (uri-host a) (uri-host b))))
                   (lambda (uri . maybe-bound)
                     (apply string-hash
                            (sprintf "~S ~S" (uri-host uri) (uri-port uri))
                            maybe-bound)))))

(define connections-owner
  (make-parameter (current-thread)))

(define (ensure-local-connections)
  (unless (eq? (connections-owner) (current-thread))
    (connections (make-hash-table equal?))
    (connections-owner (current-thread))))

(cond-expand
  ((not has-port-closed)
   (define (port-closed? p)
     (##sys#check-port p 'port-closed?)
     (##sys#slot p 8)))
  (else))

(define (connection-dropped? con)
  (or (port-closed? (http-connection-inport con))
      (port-closed? (http-connection-outport con))
      (condition-case
          (and (char-ready? (http-connection-inport con))
               (eof-object? (peek-char (http-connection-inport con))))
        ;; Assume connection got reset when we get this exception
        ((exn i/o net) #t))))

(define (get-connection uri)
  (ensure-local-connections)
  (and-let* ((con (hash-table-ref/default (connections) uri #f)))
    (if (connection-dropped? con)
        (begin (close-connection! uri) #f)
        con)))

(define (add-connection! uri con)
  (ensure-local-connections)
  (hash-table-set! (connections) uri con))

(define (close-connection! uri-or-con)
  (ensure-local-connections)
  (and-let* ((con (if (http-connection? uri-or-con)
                      uri-or-con
                      (hash-table-ref/default (connections) uri-or-con #f))))
    (close-input-port (http-connection-inport con))
    (close-output-port (http-connection-outport con))
    (hash-table-delete! (connections) (http-connection-base-uri con))))

(define (close-all-connections!)
  (ensure-local-connections)
  (hash-table-walk
   (connections)
   (lambda (uri con)
     (hash-table-delete! (connections) uri)
     (close-input-port (http-connection-inport con))
     (close-output-port (http-connection-outport con)))))

;; Imports from the openssl egg, if available
(define (dynamic-import module symbol default)
  (handle-exceptions _ default (eval `(let () (use ,module) ,symbol))))

(define ssl-connect
  (dynamic-import 'openssl 'ssl-connect (lambda (h p) (values #f #f))))

(define (default-server-connector uri proxy)
  (let ((remote-end (or proxy uri)))
    (case (uri-scheme remote-end)
      ((#f http) (tcp-connect (uri-host remote-end) (uri-port remote-end)))
      ((https) (receive (in out)
                   (ssl-connect (uri-host remote-end)
                                (uri-port remote-end))
                 (if (and in out)       ; Ugly, but necessary
                     (values in out)
                     (http-client-error
                      'ssl-connect
                      (conc "Unable to connect over HTTPS. To fix this, "
                            "install the openssl egg and try again")
                      (list (uri->string uri))
                      'missing-openssl-egg
                      'request-uri uri 'proxy proxy))))
      (else (http-client-error 'ensure-connection!
                               "Unknown URI scheme"
                               (list (uri-scheme remote-end))
                               'unsupported-uri-scheme
                               'uri-scheme (uri-scheme remote-end)
                               'request-uri uri 'proxy proxy)))))

(define server-connector (make-parameter default-server-connector))

(define (ensure-connection! uri)
  (or (get-connection uri)
      (let ((proxy ((determine-proxy) uri)))
        (receive (in out) ((server-connector) uri proxy)
          (let ((con (make-http-connection uri in out proxy)))
            (add-connection! uri con)
            con)))))

(define (make-delimited-input-port port len)
  (if (not len)
      port ;; no need to delimit anything
      (let ((pos 0))
        (make-input-port
         (lambda ()                     ; read-char
           (if (= pos len)
               #!eof
               (let ((char (read-char port)))
                 (set! pos (add1 pos))
                 char)))
         (lambda ()                     ; char-ready?
           (or (= pos len) (char-ready? port)))
         (lambda ()                     ; close
           (close-input-port port))
         (lambda ()                     ; peek-char
           (if (= pos len)
               #!eof
               (peek-char port)))
         (lambda (p bytes buf off)      ; read-string!
           (let* ((bytes (min bytes (- len pos)))
                  (bytes-read (read-string! bytes buf port off)))
             (set! pos (+ pos bytes-read))
             bytes-read))
         (lambda (p limit)              ; read-line
           (if (= pos len)
               #!eof
               (let* ((bytes-left (- len pos))
                      (limit (min (or limit bytes-left) bytes-left))
                      (line (read-line port limit)))
                 (unless (eof-object? line)
                         (set! pos (+ pos (string-length line))))
                 line)))))))

(define discard-remaining-data!
  (let ((buf (make-string 1024)))       ; Doesn't matter, discarded anyway
    (lambda (response port)
      ;; If header not available or no response object passed, this reads until EOF
      (let loop ((len (and response
                           (header-value
                            'content-length (response-headers response)))))
        (if len
            (when (> len 0)
              (loop (- len (read-string! len buf port))))
            (when (> (read-string! (string-length buf) buf port) 0)
              (loop #f)))))))

(define (add-headers req)
  (let* ((uri (request-uri req))
         (cookies (get-cookies-for-uri (request-uri req)))
         (h `(,@(if (not (null? cookies)) `((cookie . ,cookies)) '())
              (host ,(cons (uri-host uri) (and (not (uri-default-port? uri))
                                               (uri-port uri))))
              ,@(if (and (client-software) (not (null? (client-software))))
                    `((user-agent ,(client-software)))
                    '()))))
    (update-request req
                    headers: (headers h (request-headers req)))))

(define (http-client-error loc msg args specific . rest)
  (raise (make-composite-condition
          (make-property-condition 'exn 'location loc 'message msg 'arguments args)
          (make-property-condition 'http)
          (apply make-property-condition specific rest))))

;; RFC 2965, section 3.3.3
(define (cookie-eq? a-name a-info b-name b-info)
  (and (string-ci=? a-name b-name)
       (string-ci=? (alist-ref 'domain a-info) (alist-ref 'domain b-info))
       (equal?      (alist-ref 'path a-info)   (alist-ref 'path b-info))))

(define (store-cookie! cookie-info set-cookie)
  (let loop ((cookie (set-cookie->cookie set-cookie))
             (jar cookie-jar))
    (cond
     ((null? jar)
      (set! cookie-jar (cons (cons cookie-info cookie) cookie-jar))
      cookie-jar)
     ((cookie-eq? (car (get-value set-cookie)) cookie-info
                  (car (get-value (cdar jar))) (caar jar))
      (set-car! jar (cons cookie-info cookie))
      cookie-jar)
     (else (loop cookie (cdr jar))))))

(define (delete-cookie! cookie-name cookie-info)
  (set! cookie-jar (remove! (lambda (c)
                              (cookie-eq? (car (get-value (cdr c))) (car c)
                                          cookie-name cookie-info))
                            cookie-jar)))

(define (domain-match? uri pattern)
  (let ((target (uri-host uri)))
    (or (string-ci=? target pattern)
        (and (string-prefix? "." pattern)
             (string-suffix-ci? pattern target)))))

(define (path-match? uri path)
  (and (uri-path-absolute? uri)
       (let loop ((path (cdr (uri-path path)))
                  (uri-path (cdr (uri-path uri))))
         (or (null? path)               ; done
             (and (not (null? uri-path))
                  (or (and (string-null? (car path)) (null? (cdr path)))

                      (and (string=? (car path) (car uri-path))
                           (loop (cdr path) (cdr uri-path)))))))))

;; Set-cookie provides some info we don't need to store; strip the
;; nonessential info
(define (set-cookie->cookie info)
  (vector (get-value info)
          (filter (lambda (p)
                    (member (car p) '(domain path version)))
                  (get-params info))))

(define (get-cookies-for-uri uri)
  (let ((uri (if (string? uri) (uri-reference uri) uri)))
    (map cdr
         (sort!
          (filter (lambda (c)
                    (let ((info (car c)))
                     (and (domain-match? uri (alist-ref 'domain info))
                          (member (uri-port uri)
                                  (alist-ref 'port info eq?
                                             (list (uri-port uri))))
                          (path-match? uri (alist-ref 'path info))
                          (if (alist-ref 'secure info)
                              (member (uri-scheme uri) '(https shttp))
                              #t))))
                  cookie-jar)
          (lambda (a b)
            (< (length (uri-path (alist-ref 'path (car a))))
               (length (uri-path (alist-ref 'path (car b))))))))))

(define (process-set-cookie! con uri r)
  (let ((prefix-contains-dots?
         (lambda (host pattern)
           (string-index host #\. 0 (string-contains-ci host pattern)))))
    (for-each (lambda (c)
                (and-let* ((path (or (get-param 'path c) uri))
                           ((path-match? uri path))
                           ;; domain must start with dot. Add to intarweb!
                           (dn (get-param 'domain c (uri-host uri)))
                           (idx (string-index dn #\.))
                           ((domain-match? uri dn))
                           ((not (prefix-contains-dots? (uri-host uri) dn))))
                  (store-cookie! `((path . ,path)
                                   (domain . ,dn)
                                   (secure . ,(get-param 'secure c))) c)))
              (header-contents 'set-cookie (response-headers r) '()))
    (for-each (lambda (c)
                (and-let* (((get-param 'version c)) ; required for set-cookie2
                           (path (or (get-param 'path c) uri))
                           ((path-match? uri path))
                           (dn (get-param 'domain c (uri-host uri)))
                           ((or (string-ci=? dn ".local")
                                (and (not (string-null? dn))
                                     (string-index dn #\. 1))))
                           ((domain-match? uri dn))
                           ((not (prefix-contains-dots? (uri-host uri) dn)))
                           ;; This is a little bit too messy for my tastes...
                           ;; Can't use #f because that would shortcut and-let*
                           (ports-value (get-param 'port c 'any))
                           (ports (if (eq? ports-value #t)
                                      (list (uri-port uri))
                                      ports-value))
                           ((or (eq? ports 'any)
                                (member (uri-port uri) ports))))
                  (store-cookie! `((path . ,path)
                                   (domain . ,dn)
                                   (port . ,(if (eq? ports 'any) #f ports))
                                   (secure . ,(get-param 'secure c))) c)))
              (header-contents 'set-cookie2 (response-headers r) '()))))

(define (call-with-output-digest primitive proc)
  (let* ((ctx-info (message-digest-primitive-context-info primitive))
         (ctx (if (procedure? ctx-info) (ctx-info) (allocate ctx-info)))
         (update-digest (message-digest-primitive-update primitive))
         (update (lambda (str) (update-digest ctx str (string-length str))))
         (outport (make-output-port update void)))
    (handle-exceptions exn
      (unless (procedure? ctx-info) (free ctx))
      (let ((result (make-string
                     (message-digest-primitive-digest-length primitive))))
        ((message-digest-primitive-init primitive) ctx)
        (proc outport)
        ((message-digest-primitive-final primitive) ctx result)
        (unless (procedure? ctx-info) (free ctx))
        (string->hex result)))))

(define (get-username/password for-request-header for-uri for-realm)
  (if (eq? for-request-header 'authorization)
      ((determine-username/password) for-uri for-realm)
      ((determine-proxy-username/password) for-uri for-realm)))

;;; TODO: We really, really should get rid of "writer" here.  Some kind of
;;; generalized way to get the digest is required.  Jeez, HTTP sucks :(
(define (basic-authenticator response response-header
                             new-request request-header uri realm writer)
  (receive (username password)
    (get-username/password request-header uri realm)
    (and username
         (update-request
          new-request
          headers: (headers `((,request-header
                               #(basic ((username . ,username)
                                        (password . ,(or password ""))))))
                            (request-headers new-request))))))

(define (digest-authenticator response response-header
                              new-request request-header uri realm writer)
  (receive (username password)
    (get-username/password request-header uri realm)
    (and username
         (let* ((hashconc
                 (lambda args
                   (message-digest-string
                    (md5-primitive) (string-join (map ->string args) ":"))))
                (authless-uri (update-uri (request-uri new-request)
                                          username: #f password: #f))
                ;; TODO: domain handling
                (h (response-headers response))
                (nonce (header-param 'nonce response-header h))
                (opaque (header-param 'opaque response-header h))
                (stale (header-param 'stale response-header h))
                ;; TODO: "md5-sess" algorithm handling
                (algorithm (header-param 'algorithm response-header h))
                (qops (header-param 'qop response-header h '()))
                (qop (cond ; Pick the strongest of the offered options
                      ((member 'auth-int qops) 'auth-int)
                      ((member 'auth qops) 'auth)
                      (else #f)))
                (cnonce (and qop (hashconc (current-seconds) realm)))
                (nc (and qop 1)) ;; TODO
                (ha1 (hashconc username realm (or password "")))
                (ha2 (if (eq? qop 'auth-int)
                         (hashconc (request-method new-request)
                                   (uri->string authless-uri)
                                   ;; Generate digest from writer's output
                                   (call-with-output-digest
                                    (md5-primitive)
                                    (lambda (p)
                                      (writer
                                       (update-request new-request port: p)))))
                         (hashconc (request-method new-request)
                                   (uri->string authless-uri))))
                (digest
                 (case qop
                   ((auth-int auth)
                    (let ((hex-nc (string-pad (number->string nc 16) 8 #\0)))
                      (hashconc ha1 nonce hex-nc cnonce qop ha2)))
                   (else
                    (hashconc ha1 nonce ha2)))))
           (update-request new-request
                           headers: (headers
                                     `((,request-header
                                        #(digest ((username . ,username)
                                                  (uri . ,authless-uri)
                                                  (realm . ,realm)
                                                  (nonce . ,nonce)
                                                  (cnonce . ,cnonce)
                                                  (qop . ,qop)
                                                  (nc . ,nc)
                                                  (response . ,digest)
                                                  (opaque . ,opaque)))))
                                     (request-headers new-request)))))))

(define http-authenticators
  (make-parameter `((basic . ,basic-authenticator)
                    (digest . ,digest-authenticator))))

(define (authenticate-request request response writer proxy-uri)
  (and-let* ((type (if (= (response-code response) 401) 'auth 'proxy))
             (resp-header (if (eq? type 'auth)
                              'www-authenticate
                              'proxy-authenticate))
             (req-header (if (eq? type 'auth)
                             'authorization
                             'proxy-authorization))
             (authtype (header-value resp-header (response-headers response)))
             (realm (header-param 'realm resp-header (response-headers response)))
             (auth-uri (if (eq? type 'auth) (request-uri request) proxy-uri))
             (authenticator (or (alist-ref authtype (http-authenticators))
                                ;; Should we really raise an error?
                                (http-client-error 'authenticate-request
                                                   "Unknown authentication type"
                                                   (list authtype)
                                                   'unknown-authtype
                                                   'authtype authtype
                                                   'request request))))
    (authenticator response resp-header request req-header
                   auth-uri realm writer)))

(define (call-with-response req writer reader)
  (let loop ((attempts 0)
             (redirects 0)
             (req req))
    (condition-case
        (let* ((con (ensure-connection! (request-uri req)))
               (req (add-headers (update-request
                                  req port: (http-connection-outport con))))
               ;; No outgoing URIs should ever contain credentials or fragments
               (req-uri (update-uri (request-uri req)
                                    fragment: #f username: #f password: #f))
               ;; RFC1945, 5.1.2: "The absoluteURI form is only allowed
               ;; when the request is being made to a proxy."
               ;; RFC2616 is a little more regular (hosts MUST accept
               ;; absoluteURI), but it says "HTTP/1.1 clients will only
               ;; generate them in requests to proxies." (also 5.1.2)
               (req-uri (if (http-connection-proxy con)
                            req-uri
                            (update-uri req-uri host: #f port: #f scheme: #f
                                        path: (or (uri-path req-uri) '(/ "")))))
               (request (write-request (update-request req uri: req-uri)))
               ;; Writer should be prepared to be called several times
               ;; Maybe try and figure out a good way to use the
               ;; "Expect: 100-continue" header to prevent too much writing?
               ;; Unfortunately RFC2616 says it's unreliable (8.2.3)...
               (_ (begin (writer request) (flush-output (request-port req))))
               (response (read-response (http-connection-inport con)))
               (cleanup! (lambda (clear-response-data?)
                           (when clear-response-data?
                             (discard-remaining-data! response
                                                      (response-port response)))
                           (unless (and (keep-alive? request)
                                        (keep-alive? response))
                             (close-connection! con)))))
          (when response (process-set-cookie! con (request-uri req) response))
          (case (and response (response-code response))
            ((#f)
             ;; If the connection is closed prematurely, we SHOULD
             ;; retry, according to RFC2616, section 8.2.4.  Currently
             ;; don't do "binary exponential backoff", which we MAY do.
             (if (or (not (max-retry-attempts)) ; unlimited?
                     (<= attempts (max-retry-attempts)))
                 (loop (add1 attempts) redirects req)
                 (http-client-error 'send-request
                                    "Server closed connection before sending response"
                                    (list (uri->string (request-uri req)))
                                    'premature-disconnection
                                    'uri (request-uri req) 'request req)))
            ;; TODO: According to spec, we should provide the user
            ;; with a choice when it's not a GET or HEAD request...
            ((301 302 303 307)
             (cleanup! #t)
             ;; Maybe we should switch to GET on 302 too?  It's not compliant,
             ;; but very widespread and there's enough software that depends
             ;; on that behaviour, which might break horribly otherwise...
             (when (= (response-code response) 303)
               (request-method-set! req 'GET)) ; Switch to GET
             (let* ((loc-uri (header-value 'location
                                           (response-headers response)))
                    (new-uri (uri-relative-to loc-uri (request-uri req))))
               (if (or (not (max-redirect-depth)) ; unlimited?
                       (< redirects (max-redirect-depth)))
                   (loop attempts
                         (add1 redirects)
                         (update-request req uri: new-uri))
                   (http-client-error 'send-request
                                      "Maximum number of redirects exceeded"
                                      (list (uri->string (request-uri request)))
                                      'redirect-depth-exceeded
                                      'uri (request-uri req)
                                      'new-uri new-uri 'request req))))
            ;; TODO: Test this
            ((305)                 ; Use proxy (for this request only)
             (cleanup! #t)
             (let ((old-determine-proxy (determine-proxy))
                   (proxy-uri (header-value 'location (response-headers response))))
               (parameterize ((determine-proxy
                               (lambda _
                                 ;; Reset determine-proxy so the proxy is really
                                 ;; used for only this one request.
                                 ;; Yes, this is a bit of a hack :)
                                 (determine-proxy old-determine-proxy)
                                 proxy-uri)))
                 (loop attempts redirects req))))
            ((401 407)   ; Unauthorized, Proxy Authentication Required
             (cond ((and (or (not (max-retry-attempts)) ; unlimited?
                             (<= attempts (max-retry-attempts)))
                         (authenticate-request req response writer
                                               (http-connection-proxy con)))
                    => (lambda (new-req)
                         (cleanup! #t)
                         (loop (add1 attempts) redirects new-req)))
                   (else ;; pass it on, we can't throw an error here
                    (let ((data (reader response)))
                      (values data (request-uri request) response)))))
            (else (let ((data (reader response)))
                    (cleanup! #f)
                    (values data req response)))))
      (exn (exn i/o net)
           (close-connection! (request-uri req))
           (if (and (or (not (max-retry-attempts)) ; unlimited?
                        (<= attempts (max-retry-attempts)))
                    ((retry-request?) req))
               (loop (add1 attempts) redirects req)
               (raise exn)))
      (exn ()
           ;; Never leave the port in an unknown/inconsistent state
           ;; (the error could have occurred while reading, so there
           ;;  might be data left in the buffer)
           (close-connection! (request-uri req))
           (raise exn)))))

(define (kv-ref l k #!optional default)
  (let ((rest (and (pair? l) (memq k l))))
    (if (and rest (pair? (cdr rest))) (cadr rest) default)))

;; This really, really sucks
;; TODO: This crap probably belongs in its own egg?  Perhaps later when
;; we have server-side handling for this too.
(define (prepare-multipart-chunks boundary entries)
  (append
   (map (lambda (entry)
          (if (not (cdr entry))         ; discard #f values
              '()
              (let* ((keys (cdr entry))
                     (file (kv-ref keys file:))
                     (filename (or (kv-ref keys filename:)
                                   (and (port? file) (port-name file))
                                   (and (string? file) file)))
                     (filename (and filename
                                    (pathname-strip-directory filename)))
                     (h (headers `((content-disposition
                                    #(form-data ((name . ,(car entry))
                                                 (filename . ,filename))))
                                   ,@(if filename
                                         '((content-type application/octet-stream))
                                         '()))))
                     (hs (call-with-output-string
                           (lambda (s)
                             (unparse-headers
                              ;; Allow user headers to override ours
                              (headers (kv-ref keys headers: '()) h) s)))))
                (list "--" boundary "\r\n" hs "\r\n"
                      (cond ((string? file) (cons 'file file))
                            ((port? file) (cons 'port file))
                            ((eq? keys #t) "")
                            (else (->string keys)))
                  ;; The next boundary must always start on a new line
                  "\r\n"))))
        entries)
   (list (list "--" boundary "--\r\n"))))

(define (write-chunks output-port entries)
  (for-each (lambda (entry)
              (for-each (lambda (chunk)
                          (if (pair? chunk)
                              (let ((p (if (eq? 'file (car chunk))
                                           (open-input-file (cdr chunk))
                                           ;; Should be a port otherwise
                                           (cdr chunk))))
                                (handle-exceptions exn
                                  (begin (close-input-port p) (raise exn))
                                  (sendfile p output-port))
                                (close-input-port p))
                              (display chunk output-port)))
                        entry))
            entries))

(define (calculate-chunk-size entries)
  (call/cc
   (lambda (return)
     (fold (lambda (chunks total-size)
             (fold (lambda (chunk total-size)
                     (if (pair? chunk)
                         (if (eq? 'port (car chunk))
                             ;; Should be a file otherwise.
                             ;; We can't calculate port lengths.
                             ;; Let's just punt and hope the server
                             ;; won't return "411 Length Required"...
                             ;; (TODO: maybe try seeking it?)
                             (return #f)
                             (+ total-size (file-size (cdr chunk))))
                         (+ total-size (string-length chunk))))
                   total-size
                   chunks))
           0 entries))))

(define (call-with-input-request* uri-or-request writer reader)
  (let* ((type #f)
         (uri (cond ((uri? uri-or-request) uri-or-request)
                    ((string? uri-or-request) (uri-reference uri-or-request))
                    (else (request-uri uri-or-request))))
	 (req (if (request? uri-or-request)
                  uri-or-request
                  (make-request uri: uri method: (if writer 'POST 'GET))))
         (chunks (cond
                  ((string? writer) (list (list writer)))
                  ((and (list? writer)
                        (any (lambda (x)
                               (and (pair? x) (pair? (cdr x))
                                    (eq? (cadr x) file:)))
                             writer))
                   (let ((bd (conc "----------------Multipart-=_"
                                   (gensym 'boundary) "=_=" (current-process-id)
                                   "=-=" (current-seconds))))
                     (set! type `#(multipart/form-data ((boundary . ,bd))))
                     (prepare-multipart-chunks bd writer)))
                  ;; Default to "&" because some servers choke on ";"
                  ((list? writer)
                   (set! type 'application/x-www-form-urlencoded)
                   (list (list (or (form-urlencode writer separator: "&")
                                   (http-client-error
                                    'call-with-input-request
                                    "Invalid form data!"
                                    (list (uri->string uri) writer reader)
                                    'form-data-error
                                    'request req
                                    'form-data writer)))))
                  (else #f)))
         (req (update-request
               req
               headers: (headers
                         `(,@(if chunks
                                 `((content-length
                                    ,(calculate-chunk-size chunks)))
                                 '())
                           ,@(if type `((content-type ,type)) '()))
                         (request-headers req)))))
    (call-with-response
     req
     (cond (chunks (lambda (r)
                     (write-chunks (request-port r) chunks)
                     (finish-request-body r)))
           ((procedure? writer)
            (lambda (r)
              (writer (request-port r))
              (finish-request-body r)))
           (else (lambda x (void))))
     (lambda (response)
       (let ((port (make-delimited-input-port
                    (response-port response)
                    (header-value 'content-length (response-headers response))))
             (body? ((response-has-message-body-for-request?) response req)))
         (if (= 200 (response-class response)) ; Everything cool?
             (let ((result (and body? reader (reader port response))))
               (when body? (discard-remaining-data! #f port))
               result)
             (http-client-error
              'call-with-input-request
              ;; Message
              (sprintf (case (response-class response)
                         ((400) "Client error: ~A ~A")
                         ((500) "Server error: ~A ~A")
                         (else "Unexpected server response: ~A ~A"))
                       (response-code response) (response-reason response))
	      ;; arguments
	      (list (uri->string uri))
              ;; Specific type
              (case (response-class response)
                ((400) 'client-error)
                ((500) 'server-error)
                (else 'unexpected-server-response))
              'response response
              'body (and body? (read-string #f port)))))))))

(define (call-with-input-request uri-or-request writer reader)
  (call-with-input-request* uri-or-request writer (lambda (p r) (reader p))))

(define (with-input-from-request uri-or-request writer reader)
  (call-with-input-request uri-or-request
                           (if (procedure? writer)
                               (lambda (p) (with-output-to-port p writer))
                               writer) ;; Assume it's an alist or #f
                           (lambda (p) (with-input-from-port p reader))))

)
