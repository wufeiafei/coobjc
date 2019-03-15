//
//  COCoroutine.m
//  coobjc
//
//  Copyright © 2018 Alibaba Group Holding Limited All rights reserved.
//
//   Licensed under the Apache License, Version 2.0 (the "License");
//   you may not use this file except in compliance with the License.
//   You may obtain a copy of the License at
//
//   http://www.apache.org/licenses/LICENSE-2.0
//
//   Unless required by applicable law or agreed to in writing, software
//   distributed under the License is distributed on an "AS IS" BASIS,
//   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//   See the License for the specific language governing permissions and
//   limitations under the License.

#import "COCoroutine.h"
#import "COChan.h"
#import "coroutine.h"
#import "co_queue.h"

NSString *const COInvalidException = @"COInvalidException";

@interface COCoroutine ()

@property(nonatomic, assign) BOOL isFinished;
@property(nonatomic, assign) BOOL isCancelled;
@property(nonatomic, assign) BOOL isResume;
@property(nonatomic, strong) NSMutableDictionary *parameters;
@property(nonatomic, copy, nullable) dispatch_block_t joinBlock;
@property(nonatomic, strong) NSMutableArray *subroutines;
@property(nonatomic, weak) COCoroutine *parent;

- (void)execute;

- (void)setParam:(id _Nullable )value forKey:(NSString *_Nonnull)key;
- (id _Nullable )paramForKey:(NSString *_Nonnull)key;

- (void)removeChild:(COCoroutine *)child;
- (void)addChild:(COCoroutine *)child;

@end

COCoroutine *co_get_obj(coroutine_t  *co) {
    if (co == nil) {
        return nil;
    }
    id obj = (__bridge id)coroutine_getuserdata(co);
    if ([obj isKindOfClass:[COCoroutine class]]) {
        return obj;
    }
    return nil;
}

NSError *co_getError() {
    return [COCoroutine currentCoroutine].lastError;
}


BOOL co_setspecific(NSString *key, id _Nullable value) {
    COCoroutine *co = [COCoroutine currentCoroutine];
    if (!co) {
        return NO;
    }
    [co setParam:value forKey:key];
    return YES;
}

id _Nullable co_getspecific(NSString *key) {
    COCoroutine *co = [COCoroutine currentCoroutine];
    if (!co) {
        return nil;
    }
    return [co paramForKey:key];
}

static void co_exec(coroutine_t  *co) {
    
    COCoroutine *coObj = co_get_obj(co);
    if (coObj) {
        [coObj execute];
        
        coObj.isFinished = YES;
        if (coObj.finishedBlock) {
            coObj.finishedBlock();
            coObj.finishedBlock = nil;
        }
        if (coObj.joinBlock) {
            coObj.joinBlock();
            coObj.joinBlock = nil;
        }
        [coObj.parent removeChild:coObj];
    }
}

static void co_obj_dispose(void *coObj) {
    COCoroutine *obj = (__bridge_transfer id)coObj;
    if (obj) {
        obj.co = nil;
    }
}

@implementation COCoroutine


- (void)execute {
    if (self.execBlock) {
        self.execBlock();
    }
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _parameters = [[NSMutableDictionary alloc] init];
    }
    return self;
}

- (void)setParam:(id)value forKey:(NSString *)key {
    [_parameters setValue:value forKey:key];
}

- (id)paramForKey:(NSString *)key {
    return [_parameters valueForKey:key];
}

- (BOOL)isCurrentQueue {
    if (co_get_current_queue() == self.queue) {
        return YES;
    }
    return NO;
}

+ (COCoroutine *)currentCoroutine {
    return co_get_obj(coroutine_self());
}

+ (BOOL)isActive {
    coroutine_t  *co = coroutine_self();
    if (co) {
        if (co->is_cancelled) {
            return NO;
        } else {
            return YES;
        }
    } else {
        @throw [NSException exceptionWithName:COInvalidException reason:@"isActive must called in a routine" userInfo:@{}];
    }
}

- (instancetype)initWithBlock:(void (^)(void))block onQueue:(dispatch_queue_t)queue stackSize:(NSUInteger)stackSize {
    self = [super init];
    if (self) {
        _execBlock = [block copy];
        _queue = queue ?: co_get_current_queue();
        
        coroutine_t  *co = coroutine_create((void (*)(void *))co_exec);
        if (stackSize > 0 && stackSize < 1024*1024) {   // Max 1M
            co->stack_size = (uint32_t)((stackSize % 16384 > 0) ? ((stackSize/16384 + 1) * 16384) : stackSize);        // Align with 16kb
        }
        _co = co;
        coroutine_setuserdata(co, (__bridge_retained void *)self, co_obj_dispose);
    }
    return self;
}

+ (instancetype)coroutineWithBlock:(void (^)(void))block onQueue:(dispatch_queue_t)queue {
    
    return [self coroutineWithBlock:block onQueue:queue stackSize:0];
}
    
+ (instancetype)coroutineWithBlock:(void(^)(void))block onQueue:(dispatch_queue_t)queue stackSize:(NSUInteger)stackSize {

    return [[[self class] alloc] initWithBlock:block onQueue:queue stackSize:stackSize];

}

- (void)performBlockOnQueue:(dispatch_block_t)block {
    dispatch_queue_t queue = self.queue;
    if (queue == co_get_current_queue()) {
        block();
    } else {
        dispatch_async(queue, block);
    }
}

- (void)_internalCancel {
    
    if (_isCancelled) {
        return;
    }
    NSArray *subroutines = self.subroutines.copy;;
    if (subroutines.count) {
        [subroutines enumerateObjectsUsingBlock:^(COCoroutine * _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
            [obj cancel];
        }];
    }
    
    _isCancelled = YES;
    
    coroutine_t *co = self.co;
    if (co) {
        co->is_cancelled = YES;
    }
    
    COChan *chan = self.currentChan;
    if (chan) {
        [chan cancel];
    }
}

- (void)cancel {
    [self performBlockOnQueue:^{
        [self _internalCancel];
    }];
}

- (void)addChild:(COCoroutine *)child {
    [self.subroutines addObject:child];
}

- (void)removeChild:(COCoroutine *)child {
    [self.subroutines removeObject:child];
}

- (COCoroutine *)resume {
    COCoroutine *currentCo = [COCoroutine currentCoroutine];
    BOOL isSubroutine = currentCo.queue == self.queue ? YES : NO;
    dispatch_async(self.queue, ^{
        if (self.isResume) {
            return;
        }
        if (isSubroutine) {
            self.parent = currentCo;
            [currentCo addChild:self];
        }
        self.isResume = YES;
        coroutine_resume(self.co);
    });
    return self;
}

- (void)resumeNow {
    COCoroutine *currentCo = [COCoroutine currentCoroutine];
    BOOL isSubroutine = currentCo.queue == self.queue ? YES : NO;
    [self performBlockOnQueue:^{
        if (self.isResume) {
            return;
        }
        if (isSubroutine) {
            self.parent = currentCo;
            [currentCo addChild:self];
        }
        self.isResume = YES;
        coroutine_resume(self.co);
    }];
}

- (void)addToScheduler {
    [self performBlockOnQueue:^{
        coroutine_add(self.co);
    }];
}

- (void)join {
    COChan *chan = [COChan chanWithBuffCount:1];
    [self performBlockOnQueue:^{
        if ([self isFinished]) {
            [chan send_nonblock:@(1)];
        }
        else{
            [self setJoinBlock:^{
                [chan send_nonblock:@(1)];
            }];
        }
    }];
    [chan receive];
}

- (void)cancelAndJoin {
    COChan *chan = [COChan chanWithBuffCount:1];
    [self performBlockOnQueue:^{
        if ([self isFinished]) {
            [chan send_nonblock:@(1)];
        }
        else{
            [self setJoinBlock:^{
                [chan send_nonblock:@(1)];
            }];
            [self _internalCancel];
        }
    }];
    [chan receive];
}

@end


id co_await(id awaitable) {
    coroutine_t  *t = coroutine_self();
    if (t == nil) {
        @throw [NSException exceptionWithName:COInvalidException reason:@"Cannot call co_await out of a coroutine" userInfo:nil];
    }
    if (t->is_cancelled) {
        return nil;
    }
    
    if ([awaitable isKindOfClass:[COChan class]]) {
        COCoroutine *co = co_get_obj(t);
        co.lastError = nil;
        id val = [(COChan *)awaitable receive];
        return val;
    } else if ([awaitable isKindOfClass:[COPromise class]]) {
        
        COChan *chan = [COChan chanWithBuffCount:1];
        COCoroutine *co = co_get_obj(t);
        
        co.lastError = nil;
        
        COPromise *promise = awaitable;
        [[promise
          then:^id _Nullable(id  _Nullable value) {
              [chan send_nonblock:value];
              return value;
          }]
         catch:^(NSError * _Nonnull error) {
             co.lastError = error;
             [chan send_nonblock:nil];
         }];

        [chan onCancel:^(COChan * _Nonnull chan) {
            [promise cancel];
        }];
        
        id val = [chan receive];
        return val;
        
    } else {
        @throw [NSException exceptionWithName:COInvalidException
                                       reason:[NSString stringWithFormat:@"Cannot await object: %@.", awaitable]
                                     userInfo:nil];
    }
}

NSArray *co_batch_await(NSArray * awaitableList) {
    
    coroutine_t  *t = coroutine_self();
    if (t == nil) {
        @throw [NSException exceptionWithName:COInvalidException
                                       reason:@"Cannot run co_batch_await out of a coroutine"
                                     userInfo:nil];
    }
    if (t->is_cancelled) {
        return nil;
    }
    
    NSMutableArray *resultAwaitable = [[NSMutableArray alloc] initWithCapacity:awaitableList.count];

    for (id awaitable in awaitableList) {
        
        if ([awaitable isKindOfClass:[COChan class]]) {
            
            [resultAwaitable addObject:awaitable];
           
        } else if ([awaitable isKindOfClass:[COPromise class]]) {
            

            COChan *chan = [COChan chanWithBuffCount:1];

            COCoroutine *co = co_get_obj(t);
            
            COPromise *promise = awaitable;
            [[promise
              then:^id _Nullable(id  _Nullable value) {
                  
                  [chan send_nonblock:value];
                  return value;
              }]
             catch:^(NSError * _Nonnull error) {
                 co.lastError = error;
                 [chan send_nonblock:error];
             }];
            
            [chan onCancel:^(COChan * _Nonnull chan) {
                [promise cancel];
            }];
            
            [resultAwaitable addObject:chan];
            
        } else {
            @throw [NSException exceptionWithName:COInvalidException
                                           reason:[NSString stringWithFormat:@"Cannot await object: %@.", awaitable]
                                         userInfo:nil];
        }
        
        
    }
    
    NSMutableArray *result = [[NSMutableArray alloc] initWithCapacity:awaitableList.count];
    for (COChan *chan in resultAwaitable) {
        id val = co_await(chan);
        [result addObject:val ? val : [NSNull null]];
    }
    return result.copy;
}



