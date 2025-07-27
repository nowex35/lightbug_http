nowex35@nowex7:~/MOJO/lightbug_http$ pixi run mojo working_mcp_server.mojo
Included from /home/nowex35/MOJO/lightbug_http/lightbug_http/mcp/__init__.mojo:1:
Included from /home/nowex35/MOJO/lightbug_http/lightbug_http/mcp/__init__.mojo:8:
/home/nowex35/MOJO/lightbug_http/lightbug_http/mcp/transport.mojo:126:38: error: 'Variant[JSONRPCRequest, JSONRPCResponse, JSONRPCNotification]' value has no attribute 'get'
                var request = message.get[JSONRPCRequest]()[]
                              ~~~~~~~^
Included from /home/nowex35/MOJO/lightbug_http/lightbug_http/mcp/__init__.mojo:1:
Included from /home/nowex35/MOJO/lightbug_http/lightbug_http/mcp/__init__.mojo:8:
/home/nowex35/MOJO/lightbug_http/lightbug_http/mcp/transport.mojo:127:63: error: invalid call to 'handle_request': method argument #0 cannot be converted from '!lit.typecheckerror' to 'JSONRPCRequest'
                var response = self.mcp_handler.handle_request(request)
                               ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~^~~~~~~~~
Included from /home/nowex35/MOJO/lightbug_http/lightbug_http/mcp/__init__.mojo:1:
Included from /home/nowex35/MOJO/lightbug_http/lightbug_http/mcp/__init__.mojo:7:
/home/nowex35/MOJO/lightbug_http/lightbug_http/mcp/server.mojo:156:8: note: function declared here
    fn handle_request(mut self, request: JSONRPCRequest) raises -> JSONRPCResponse:
       ^
Included from /home/nowex35/MOJO/lightbug_http/lightbug_http/mcp/__init__.mojo:1:
Included from /home/nowex35/MOJO/lightbug_http/lightbug_http/mcp/__init__.mojo:8:
/home/nowex35/MOJO/lightbug_http/lightbug_http/mcp/transport.mojo:128:53: error: invalid call to 'serialize_response': method argument #0 cannot be converted from '!lit.typecheckerror' to 'JSONRPCResponse'
                return serializer.serialize_response(response)
                       ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~^~~~~~~~~~
Included from /home/nowex35/MOJO/lightbug_http/lightbug_http/mcp/__init__.mojo:1:
Included from /home/nowex35/MOJO/lightbug_http/lightbug_http/mcp/__init__.mojo:8:
Included from /home/nowex35/MOJO/lightbug_http/lightbug_http/mcp/transport.mojo:14:
/home/nowex35/MOJO/lightbug_http/lightbug_http/mcp/parser.mojo:114:8: note: function declared here
    fn serialize_response(self, response: JSONRPCResponse) -> String:
       ^
Included from /home/nowex35/MOJO/lightbug_http/lightbug_http/mcp/__init__.mojo:1:
Included from /home/nowex35/MOJO/lightbug_http/lightbug_http/mcp/__init__.mojo:8:
/home/nowex35/MOJO/lightbug_http/lightbug_http/mcp/transport.mojo:130:43: error: 'Variant[JSONRPCRequest, JSONRPCResponse, JSONRPCNotification]' value has no attribute 'get'
                var notification = message.get[JSONRPCNotification]()[]
                                   ~~~~~~~^
Included from /home/nowex35/MOJO/lightbug_http/lightbug_http/mcp/__init__.mojo:1:
Included from /home/nowex35/MOJO/lightbug_http/lightbug_http/mcp/__init__.mojo:8:
/home/nowex35/MOJO/lightbug_http/lightbug_http/mcp/transport.mojo:131:53: error: invalid call to 'handle_notification': method argument #0 cannot be converted from '!lit.typecheckerror' to 'JSONRPCNotification'
                self.mcp_handler.handle_notification(notification)
                ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~^~~~~~~~~~~~~~
Included from /home/nowex35/MOJO/lightbug_http/lightbug_http/mcp/__init__.mojo:1:
Included from /home/nowex35/MOJO/lightbug_http/lightbug_http/mcp/__init__.mojo:7:
/home/nowex35/MOJO/lightbug_http/lightbug_http/mcp/server.mojo:176:8: note: function declared here
    fn handle_notification(mut self, notification: JSONRPCNotification) raises:
       ^
/home/nowex35/MOJO/lightbug_http/.pixi/envs/default/bin/mojo: error: failed to parse the provided Mojo source module