require 'mocha'
should = require 'should'
jobQ = require '../index'
Worker = jobQ.Worker
Queue = jobQ.Queue
redisDriver = require 'redis'
parseRedisUrl = require('parse-redis-url')(redisDriver)
async = require 'async'

# Global redis client used for setting up tests
redis = null
w1 = null 
w2 = null 
w3 = null 

createNewWorker = (done) ->
   jobQ.createWorkerWithUrl null, (err, worker) ->
      return done(err) if err
      worker.addHandler 'test', (job, cb) -> setTimeout(cb, 50)
      worker.addHandler 'testLock', (job, cb) -> setTimeout(cb, 100)
      worker.on('error', (description) -> throw new Error(description))
      worker.on('job_error', (err) -> throw new Error(err))
      done(null, worker)

describe "Queue", () ->

   before (done) ->
      parseRedisUrl.createClient null, (err, client) ->
         redis = client
         done(err)

   beforeEach (done) ->
      redis.multi()
      .ltrim('job_queue', 0, 0)
      .lpop('job_queue')
      .exec(done)

   after () -> redis.end()

   it "should queue new job", (done) ->
      jobQ.createQueueWithUrl null, (err, queue) ->
         queue.createJob 'test', { payload: 'something' }, (err) ->
            return done(err) if err
            redis.rpop 'job_queue', (err, jobDef) ->
               return done(err) if err
               job = JSON.parse(jobDef)
               job.id.should.equal('test')
               job.payload.should.equal('something')
               done()

   it "should queue new locking job", (done) ->
      jobQ.createQueueWithUrl null, (err, queue) ->
         queue.createLockingJob 'testLock', 'l1', { payload: 'blah' }, (err) ->
            return done(err) if err
            redis.rpop 'job_queue', (err, jobDef) ->
               return done(err) if err
               job = JSON.parse(jobDef)
               job.id.should.equal('testLock')
               job.payload.should.equal('blah')
               job.lockingId.should.equal('l1')
               done()

describe "Worker", () ->

   before (done) ->
      parseRedisUrl.createClient null, (err, client) ->
         redis = client
         done(err)

   beforeEach (done) ->
      redis.multi()
      .ltrim('job_queue', 0, 0)
      .lpop('job_queue')
      .exec(done)

   after () -> redis.end()

   describe "Basic Processing", () ->

      beforeEach (done) ->
         redis.multi()
         .ltrim("job_queue", -1, 0)
         .lpush("job_queue", '{"id":"test","job_num":1}')
         .lpush("job_queue", '{"id":"test","job_num":2}')
         .lpush("job_queue", '{"id":"test","job_num":3}')
         .exec done

      it "should process all queued jobs", (done) ->
         createNewWorker (err, worker) ->
            return done(err) if err

            processCount = 0
            completeCount = 0

            worker.on "process", () -> processCount++
            worker.on "complete", () -> completeCount++
            worker.on "waiting", () -> 
               processCount.should.equal(3)
               completeCount.should.equal(processCount)
               worker.dispose()
               done()
            worker.start()

      it "should process queued jobs without lock in order", (done) ->
         createNewWorker (err, worker) ->
            return done(err) if err
            processCount = 0
            
            worker.on "process", (job) ->
               job.job_num.should.equal(++processCount)
            worker.on "waiting", () -> 
               processCount.should.equal(3)
               worker.dispose()
               done()
            worker.start()

      it "should process queued jobs in order when parallelized", (done) ->    
         async.parallel
            w1: (done) -> createNewWorker(done)
            w2: (done) -> createNewWorker(done)
         , (err, workers) ->
            return done(err) if err
            w1 = workers.w1
            w2 = workers.w2
            processCount = 0

            w1.on "process", (job) -> 
               job.job_num.should.equal(++processCount)
            
            w2.on "process", (job) -> 
               job.job_num.should.equal(++processCount)
            
            w2Done = false

            w1.on "waiting", () -> 
               processCount.should.equal(3)
               w2Done.should.be.true
               w1.dispose()
               done() # call done here because it should be the last one
               
            w2.on "waiting", () -> 
               w2.dispose()
               w2Done = true
            
            w1.start()
            setTimeout (-> w2.start()), 5
            

   describe "Waiting Behavior", () ->

      it "should change from waiting state when a job is queued", (done) ->
         createNewWorker (err, worker) ->
            return done(err) if err
            completed = 0
            startedWaiting = false
            jobDef = '{"id":"test","somevalue":1}'
            
            worker.on "complete", () -> completed++            
            worker.on "waiting", () ->
               if completed == 0
                  startedWaiting = true
                  setTimeout () ->
                     redis.multi()
                     .ltrim("job_queue", -1, 0)
                     .lpush("job_queue", jobDef)
                     .publish("new_job", jobDef)
                     .exec()
                  , 10
               else
                  completed.should.equal(1)
                  startedWaiting.should.be.true
                  worker.dispose()
                  done()
            worker.start()

      it "should only process a job once when multiple workers waiting", (done) ->
         async.parallel
            w1: (done) -> createNewWorker(done)
            w2: (done) -> createNewWorker(done)
         , (err, workers) ->
            return done(err) if err
            w1 = workers.w1
            w2 = workers.w2
            jobDef = '{"id":"test","job_num":1}'
            completed = 0
            process = 0

            completedCallback = () ->
               completed++
               setTimeout () ->
                  process.should.equal(1)
                  completed.should.equal(1)
                  w1.stop()
                  w2.stop()
                  done()
               , 110

            w1.on "complete", completedCallback
            w2.on "complete", completedCallback
            w1.on "process", () -> process++
            w2.on "process", () -> process++

            w1.on "waiting", () ->
               return unless completed == 0
               # This is required in case w2 gets job instead of w1
               setTimeout () ->
                  return unless completed == 0
                  redis.multi()
                  .ltrim("job_queue", -1, 0)
                  .lpush("job_queue", jobDef)
                  .publish("new_job", jobDef)
                  .exec()
               , 60

            w1.start()
            w2.start()

   describe "Processing with Locking", () ->

      beforeEach (done) ->
         redis.multi()
         .del("lock:t")
         .ltrim("job_queue", -1, 0)
         .lpush("job_queue", '{"id":"testLock","lockingId":"t","job_num":1}')
         .lpush("job_queue", '{"id":"test","job_num":2}')
         .lpush("job_queue", '{"id":"testLock","lockingId":"t","job_num":3}')
         .exec done

      it "should lock jobs correctly", (done) ->    
         async.parallel
            w1: (done) -> createNewWorker(done)
            w2: (done) -> createNewWorker(done)
         , (err, workers) ->
            return done(err) if err
            w1 = workers.w1
            w2 = workers.w2
            processCount = 0
            completed = 0

            w1.on "complete", (job) -> 
               [1,3].should.include(job.job_num)
               completed++
               
            w2.on "complete", (job) -> 
               job.job_num.should.equal(2)
               completed++

            w1.on "waiting", () -> 
               completed.should.equal(3)
               w1.stop()
               done()

            w1.start()
            setTimeout (-> w2.start()), 10
