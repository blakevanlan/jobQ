var Queue = function (client) {
   this.redis = client;
};

Queue.prototype.createJob = function (id, data, done) {
   data = data || {};
   data.id = id;
   var jobDef = JSON.stringify(data);
   this.redis.multi()
   .lpush('job_queue', jobDef)
   .publish('new_job', jobDef)
   .exec(done);
};

Queue.prototype.createLockingJob = function (id, lock, data, done) {
   data = data || {};
   if (!lock) throw new Error('Lock cannot be undefined')
   data.lockingId = lock;
   this.createJob(id, data, done);
}

module.exports = Queue;
