var EventEmitter = require('events').EventEmitter;
var util = require('util');

var Worker = function (client) {
   EventEmitter.call(this);
   this.state = 'stopped';
   this.redis = client;
   this.handlers = {};

   this.redis.on('message', (function (channel, message) {
      if (message && channel == 'new_job' && this.state == 'waiting') {
         this.state = 'reactivating';
         this.redis.unsubscribe('new_job', (function (err) {
            if (err) {
               this.emit('error', 'Failed to reactivate', err);
               this.state = 'error';
               return;
            }
            this.state = 'active';
            this.emit('active');
            this._nextJob();
         }).bind(this));
      }
   }).bind(this));

   this.redis.on('error', (function (err) {
      this.emit('error', 'Redis error', err);
      this.state = 'error';
   }).bind(this));

   this.redis.on('end', (function () {
      this.redis.unsubscribe('new_job');
   }).bind(this));

   this.redis.on('ready', (function () {
      // Reconnect to subscribe if in waiting state
      if (this.state == 'waiting') {
         this.redis.subscribe('new_job', (function (err) {
            this.emit('error', 'Failed to resubscribe', err);
            this.state = 'error';
         }).bind());
      }
   }).bind(this));
};
util.inherits(Worker, EventEmitter);

Worker.prototype.start = function () {
   this.state = 'active';
   this.emit('start');
   this._nextJob();
};

Worker.prototype.stop = function (cb) {
   if (this.state == 'stopped') {
      if (cb) cb();
      return;
   }
   this.redis.unsubscribe('new_job', (function (err) {
      if (err) {
         this.emit('error', 'Failed to stop', err);
         this.state = 'error';
         if (cb) cb(err);
      } else {
         this.state = 'stopped';
         this.emit('stop');
         if (cb) cb();
      }
   }).bind(this));
};

Worker.prototype.dispose = function () {
   this.stop((function() {
      this.redis.end();
   }).bind(this));
}

Worker.prototype.addHandler = function (jobId, handler) {
   if (handler.length != 2)
      throw new Error('Handler must take two parameters.');
   this.handlers[jobId] = handler;
};

Worker.prototype._wait = function (cb) {
   // Subscribe so it activates when a job is added
   this.redis.subscribe('new_job', (function (err) {
      if (err) {
         this.emit('error', 'Failed to start waiting', err);
         if (cb) cb(err);
      } else {
         this.state = 'waiting';
         this.emit('waiting');
         if (cb) cb();
      }
   }).bind(this));
};

Worker.prototype._nextJob = function (skip) {
   skip = skip || 0;
   this.redis.lindex('job_queue', -1 - skip, (function (err, jobDef) {
      if (err) {
         this.emit('error', 'Failed to lookup job', err);
         return;
      }

      // Can't do anything if jobDef is empty so go back to waiting.
      if (!jobDef) {
         return this._wait();
      }
      this._process(jobDef, skip);
   }).bind(this));
};

Worker.prototype._process = function (jobDef, index) {
   index = index || 0;

   // Try to create job from jobDef JSON blob.
   try {
      var job = JSON.parse(jobDef);
   } catch (err) {
      // Emit the job_error event and then remove the job from the queue.
      this.emit('job_error', 'Invalid JSON', jobDef);
      this.redis.lrem('job_queue', -1, jobDef, (function (err, result) {
         this._nextJob(1);
      }).bind(this));
      return;
   }

   // Check to make sure that this job has a handler.
   if (!job.id || !this.handlers[job.id]) {
      this.emit('job_error', 'No handler for job', job);
      return this._nextJob(1);
   }

   // Function to process job and then look for another job.
   var run = function () {


      // Try to remove the job
      this.redis.lrem('job_queue', -1, jobDef, (function (err, result) {
         // Function to unlock the job if the current job is locking.
         var unlock = function () {
            if (job.lockingId) {
               // Release lock
               this.redis.del('lock:' + job.lockingId, (function (err) {
                  this._nextJob(0);
               }).bind(this));
            } else {
               this._nextJob(0);
            }   
         };
      
         // Move to next job if failed to remove; ensures multiple workers don't
         // work on the same job.
         if (result == 0) {
            return this._nextJob(index + 1)
         }
         
         this.emit('process', job);
         
         // Run the job and report any errors.
         try {
            this.handlers[job.id](job, (function (err) {
               if (err) {
                  this.emit('job_error', err, job);
               } else {
                  this.emit('complete', job);
               }
               unlock.call(this);
            }).bind(this));
         } catch (err) {
            this.emit('job_error', err, job);
            unlock.call(this);
         }
      }).bind(this));
   };

   // Check if job is locked
   if (job.lockingId) {
      // Create a temporary key, this is a workaround for lack of setnxex
      // (setnx and setex combined). Required so that a command can't slip in
      // between setnx and setex causing two workers to have the same lock
      var rand = Math.round(Math.random() * new Date());
      var tempKey = 'temp:' + job.lockingId + '-' + rand;
      this.redis.multi()
         .setnx(tempKey, true)
         .expire(tempKey, 1200)
         .renamenx(tempKey, 'lock:' + job.lockingId)
         .exec((function (err, replies) {
            if (err) {
               this.emit('error', 'Failed when attempting to lock', err)
               this.state = 'error';
               return;
            }
            // Move to next job if failed to acquire lock
            if (replies[replies.length - 1] == 0) {
               this.redis.del(tempKey);
               this._nextJob(index + 1);
            } else {
               run.call(this);
            }
         }).bind(this))
   } else {
      run.call(this);
   }
};

module.exports = Worker;
