// jsrinci - Rinci/Riap JS implementation client.
//
// Version: 20130316.1
//
// This software is copyright (c) 2013 by Steven Haryanto,
// <stevenharyanto@gmail.com>.
//
// This is free software; you can redistribute it and/or modify it under the
// Artistic License 2.0.
//
// For more information about Riap::HTTP protocol, see
// https://metacpan.org/module/Riap::HTTP
//
// Usage examples:
//
// # asynchronous (callback)
// jsrinci.http_request("call", url, extra_keys, {"on_response": function(res) { ... }});
//
// # http auth
// jsrinci.http_request("call", url, {}, {"user":"admin", "password":"blah", "on_response": ...});
//
// other known copts:
//
// todo:
// - retries (int, default 2)
// - retry_delay (int, default 3)
// - support log viewing
// - support proxy

var jsrinci = jsrinci || {};

jsrinci.http_request = function(action, url, extra_keys, copts) {
    if (!extra_keys) extra_keys = {};
    if (!copts) copts = {};

    var k;
    var v;

    // copts
    var retries     = copts['retries']===undefined     ? 2 : copts['retries'];
    var retry_delay = copts['retry_delay']===undefined ? 3 : copts['retry_delay'];

    // form riap request
    var rreq = {"action": action, "ua":"jsrinci"};
    for (k in extra_keys) { rreq[k] = extra_keys[k] }

    // put all riap request keys, except some like args, to http headers
    var headers = {};
    for (k in rreq) {
        if (k.match(/^(args|fmt|loglevel|marklog|_.*)$/)) continue;
        var hk = "x-riap-" + k;
        var hv = rreq[k]
        if (hv===null || !typeof(hv).match(/^(string|number)$/)) {
            hk = hk + "-j-";
            hv = JSON.stringify(hv)
        }
        headers[hk] = hv;
    }
    headers['x-riap-fmt'] = 'json';
    //console.log("headers=" + JSON.stringify(headers)); // DEBUG

    var args = rreq['args']===undefined ? {} : rreq['args'];
    headers['content-type'] = 'application/json';

    var req_body;

    // ALT A: put args in body as json
    req_body = JSON.stringify(args);

    // ALT B: put args in form fields (not guaranteed to work on all Riap servers)
    //var postfields = {};
    //for (k in args) {
    //    v = args[k];
    //    if (v===null || !typeof(v).match(/^(string|number)$/)) {
    //        postfields[k + ':j'] = JSON.stringify(v);
    //    } else {
    //        postfields[k] = v;
    //    }
    //}
    //console.log("postfields=" + JSON.stringify(postfields)); // DEBUG
    //var postfields_s = ""
    //for (k in postfields) {
    //    postfields_s += (postfields_s.length ?  "&" : "") + escape(k) + '=' + escape(v);
    //}
    //console.log("postfields_s=" + postfields_s); // DEBUG
    //req_body = postfields_s

    headers['content-length'] = req_body.length;

    // var attempts = 0;
    // var do_retry = true;
    var xmlhttp;
    var err;
    var res;
    var data;

    while (true) {
        xmlhttp = new XMLHttpRequest();
        xmlhttp.onreadystatechange = function() {
            if (xmlhttp.readyState==4) {
                if (xmlhttp.status==200) {
                    try { data = eval(xmlhttp.responseText); }
                    catch(err) { res = [500, "Can't parse JSON: " + err] }
                    res = data;
                    // do_retry = false;
                } else {
                    res = [xmlhttp.status, "HTTP error " + xmlhttp.status];
                }
                copts['on_response'](res);
            }
        };
        if (copts['user']===undefined) {
            xmlhttp.open("POST", url, true);
        } else {
            xmlhttp.open("POST", url, true, copts['user'], copts['password']);
        }
        for (k in headers) { xmlhttp.setRequestHeader(k, headers[k]) }
        xmlhttp.send(req_body);

        //if (!do_retry) break;
        //attempts++;
        //if (attempts > retries) break;
        //sleep(retry_delay);

        break;
    }
};

