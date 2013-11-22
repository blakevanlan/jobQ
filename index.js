var redis = require('redis');
var parseRedisUrl = require('parse-redis-url')(redis);
var Worker = require('./lib/Worker');
var Queue = require('./lib/Queue');

var createWithUrl = function (Type) {
   return function (redisUrl, done) {
      parseRedisUrl.createClient(redisUrl, function (err, client) {
         if (err) return done(err);
         done(null, new Type(client));
      });
   };
};

module.exports = {
   Worker: Worker,
   Queue: Queue,
   createWorkerWithUrl: createWithUrl(Worker),
   createQueueWithUrl: createWithUrl(Queue)
};