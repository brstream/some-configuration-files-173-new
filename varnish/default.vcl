# This is a basic VCL configuration file for varnish.  See the vcl(7)
# man page for details on VCL syntax and semantics.
# 
# Default backend definition.  Set this to point to your content
# server.
# 
# This is the NGINX server:
backend default {
    .host = "127.0.0.1";
    .port = "8080";
}

# Only allow purging from specific IPs
acl purge {
	"localhost";
	"127.0.0.1";
}
# 
# Below is a commented-out copy of the default VCL logic.  If you
# redefine any of these subroutines, the built-in logic will be
# appended to your code.
sub vcl_recv {
    # Handle compression correctly. Different browsers send different
    # "Accept-Encoding" headers, even though they mostly support the same
    # compression mechanisms. By consolidating compression headers into
    # a consistent format, we reduce the cache size and get more hits.
    # @see: http:// varnish.projects.linpro.no/wiki/FAQ/Compression
    if (req.http.Accept-Encoding) {
        if (req.http.Accept-Encoding ~ "gzip") {
            # If the browser supports it, we'll use gzip.
            set req.http.Accept-Encoding = "gzip";
        }
        else if (req.http.Accept-Encoding ~ "deflate") {
            # Next, try deflate if it is supported.
            set req.http.Accept-Encoding = "deflate";
        }
        else {
            # Unknown algorithm. Remove it and send unencoded.
            unset req.http.Accept-Encoding;
        }
    }
 
    # Set client IP
    if (req.http.x-forwarded-for) {
        set req.http.X-Forwarded-For =
        req.http.X-Forwarded-For + ", " + client.ip;
    } else {
        set req.http.X-Forwarded-For = client.ip;
    }
 
    # Check if we may purge (only localhost)
    if (req.request == "PURGE") {
        if (!client.ip ~ purge) {
            error 405 "Not allowed.";
        }
        return(lookup);
    }
 
    if (req.request != "GET" &&
        req.request != "HEAD" &&
        req.request != "PUT" &&
        req.request != "POST" &&
        req.request != "TRACE" &&
        req.request != "OPTIONS" &&
        req.request != "DELETE") {
            # /* Non-RFC2616 or CONNECT which is weird. */
            return (pipe);
    }
 
    if (req.request != "GET" && req.request != "HEAD") {
        # /* We only deal with GET and HEAD by default */
        return (pass);
    }
 
    # admin users always miss the cache
    if( req.url ~ "^/wp-(login|admin)" || 
        req.http.Cookie ~ "wordpress_logged_in_" ){
            return (pass);
    }
 
    # Remove cookies set by Google Analytics (pattern: '__utmABC')
    if (req.http.Cookie) {
        set req.http.Cookie = regsuball(req.http.Cookie,
            "(^|; ) *__utm.=[^;]+;? *", "\1");
        if (req.http.Cookie == "") {
            remove req.http.Cookie;
        }
    }
 
    # always pass through POST requests and those with basic auth
    if (req.http.Authorization || req.request == "POST") {
        return (pass);
    }
 
    # Do not cache these paths
    if (req.url ~ "^/wp-cron\.php$" ||
        req.url ~ "^/xmlrpc\.php$" ||
        req.url ~ "^/wp-admin/.*$" ||
        req.url ~ "^/wp-includes/.*$" ||
        req.url ~ "\?s=") {
            return (pass);
    }
 
    # Define the default grace period to serve cached content
    set req.grace = 30s;
 
    # By ignoring any other cookies, it is now ok to get a page
    unset req.http.Cookie;
    return (lookup);
}
 
sub vcl_fetch {
    # remove some headers we never want to see
    unset beresp.http.Server;
    unset beresp.http.X-Powered-By;
 
    # only allow cookies to be set if we're in admin area
    if( beresp.http.Set-Cookie && req.url !~ "^/wp-(login|admin)" ){
        unset beresp.http.Set-Cookie;
    }
 
    # don't cache response to posted requests or those with basic auth
    if ( req.request == "POST" || req.http.Authorization ) {
        return (hit_for_pass);
    }
 
    # don't cache search results
    if( req.url ~ "\?s=" ){
        return (hit_for_pass);
    }
 
    # only cache status ok
    if ( beresp.status != 200 ) {
        return (hit_for_pass);
    }
 
    # If our backend returns 5xx status this will reset the grace time
    # set in vcl_recv so that cached content will be served and 
    # the unhealthy backend will not be hammered by requests
    if (beresp.status == 500) {
        set beresp.grace = 60s;
        return (restart);
    }
 
    # GZip the cached content if possible
    if (beresp.http.content-type ~ "text") {
        set beresp.do_gzip = true;
    }
 
    # if nothing abovce matched it is now ok to cache the response
    set beresp.ttl = 24h;
    return (deliver);
}
 
sub vcl_deliver {
    # remove some headers added by varnish
    unset resp.http.Via;
    unset resp.http.X-Varnish;
}
 
sub vcl_hit {
    # Set up invalidation of the cache so purging gets done properly
    if (req.request == "PURGE") {
        purge;
        error 200 "Purged.";
    }
    return (deliver);
}
 
sub vcl_miss {
    # Set up invalidation of the cache so purging gets done properly
    if (req.request == "PURGE") {
        purge;
        error 200 "Purged.";
    }
    return (fetch);
}
 
sub vcl_error {
    if (obj.status == 503) {
                # set obj.http.location = req.http.Location;
                set obj.status = 404;
        set obj.response = "Not Found";
                return (deliver);
    }
}