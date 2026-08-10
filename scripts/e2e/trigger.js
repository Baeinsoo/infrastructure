const http=require("http");
const data=JSON.stringify({matchId:"test-match-1"});
const req=http.request({host:"127.0.0.1",port:80,path:"/internal/room",method:"POST",headers:{"Content-Type":"application/json","Content-Length":Buffer.byteLength(data),"x-internal-api-key":process.env.INTERNAL_API_KEY}},res=>{let b="";res.on("data",d=>b+=d);res.on("end",()=>process.stdout.write(b))});
req.on("error",e=>console.log("ERR",e.message));req.write(data);req.end();
