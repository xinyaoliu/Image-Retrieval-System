require 'torch'
require 'nn'
require 'nngraph'
require 'optim'

-- TODO:    1, backpropagate
--          2, 正负样本


local utils = require 'utils.misc'
local DataLoader = require 'utils.DataLoader'

local LSTM = require 'LSTM'
local GRU = require 'GRU'
local RNN = require 'RNN'

cmd = torch.CmdLine()
cmd:text('Options')

-- model params
cmd:option('-model', 'lstm', 'lstm,gru or rnn')
cmd:option('-rnn_size', 256, 'Size of LSTM internal state')
cmd:option('-num_layers', 2, 'Number of layers in LSTM')
cmd:option('-embedding_size', 512, 'Size of word embeddings')
-- optimization
cmd:option('-learning_rate', 4e-4, 'Learning rate')
cmd:option('-learning_rate_decay', 0.95, 'Learning rate decay')   --0.95
cmd:option('-learning_rate_decay_after', 15, 'In number of epochs, when to start decaying the learning rate')
cmd:option('-alpha', 0.8, 'alpha for adam')
cmd:option('-beta', 0.999, 'beta used for adam')
cmd:option('-epsilon', 1e-8, 'epsilon that goes into denominator for smoothing')
cmd:option('-batch_size', 200, 'Batch size')
cmd:option('-max_epochs', 50, 'Number of full passes through the training data')
cmd:option('-dropout', 0.5, 'Dropout')
cmd:option('-init_from', '', 'Initialize network parameters from checkpoint at this path')
-- bookkeeping
cmd:option('-seed', 981723, 'Torch manual random number generator seed')
cmd:option('-save_every', 1000, 'No. of iterations after which to checkpoint')
cmd:option('-train_fc7_file', 'data/train_fc7.t7', 'Path to fc7 features of training set')
cmd:option('-train_fc7_image_id_file', 'data/train_fc7_image_id.t7', 'Path to fc7 image ids of training set')
cmd:option('-val_fc7_file', 'data/val_fc7.t7', 'Path to fc7 features of validation set')
cmd:option('-val_fc7_image_id_file', 'data/val_fc7_image_id.t7', 'Path to fc7 image ids of validation set')
cmd:option('-data_dir', '/home/liuxinyao/dataset/coco/2014', 'Data directory')
cmd:option('-checkpoint_dir', 'checkpoints', 'Checkpoint directory')
cmd:option('-savefile', 'rtv_3', 'Filename to save checkpoint to')
-- gpu/cpu
cmd:option('-gpuid', 0, '0-indexed id of GPU to use. -1 = CPU')

-- parse command-line parameters
opt = cmd:parse(arg or {})
print(opt)
torch.manualSeed(opt.seed)

-- gpu stuff
if opt.gpuid >= 0 then
    local ok, cunn = pcall(require, 'cunn')
    local ok2, cutorch = pcall(require, 'cutorch')
    if not ok then print('package cunn not found!') end
    if not ok2 then print('package cutorch not found!') end
    if ok and ok2 then
        print('using CUDA on GPU ' .. opt.gpuid .. '...')
        cutorch.setDevice(opt.gpuid + 1) -- torch is 1-indexed
        cutorch.manualSeed(opt.seed)
    else
        print('If cutorch and cunn are installed, your CUDA toolkit may be improperly configured.')
        print('Check your CUDA toolkit installation, rebuild cutorch and cunn, and try again.')
        print('Falling back to CPU mode')
        opt.gpuid = -1
    end
end

print("stage 1 done.......")

-- initialize the data loader
-- checks if .t7 data files exist
-- if they don't or if they're old,
-- they're created from scratch and loaded
local loader = DataLoader.create(opt.data_dir, opt.batch_size, opt)  --调用dataloader

print("stage 2 done.....")

-- create the directory for saving snapshots of model at different times during training
if not path.exists(opt.checkpoint_dir) then lfs.mkdir(opt.checkpoint_dir) end   --无关
-- lfs = lua file system

local do_random_init = true
if string.len(opt.init_from) > 0 then    --Initialize network parameters from checkpoint at this path 优化的参数，不管
    -- initializing model from checkpoint
    print('Loading model from checkpoint ' .. opt.init_from)
    local checkpoint = torch.load(opt.init_from)
    protos = checkpoint.protos
    do_random_init = false
else
    -- model definition         模型定义
    -- components: ltw, lti, lstm and sm
    protos = {}

    img = {}

    -- ltw: lookup table + dropout for question words           问题word的查找表，得到vector什么的？
    -- each word of the question gets mapped to its index in vocabulary
    -- and then is passed through ltw to get a vector of size `embedding_size`
    -- lookup table dimensions are `vocab_size` x `embedding_size`  30201->vocab_size
    protos.ltw = nn.Sequential()
    protos.ltw:add(nn.LookupTable(loader.q_vocab_size+1, opt.embedding_size))
    protos.ltw:add(nn.Dropout(opt.dropout))

    -- lti: fully connected layer + dropout for image features    关于图片feature的，保留，可以直接用，注意embedding size
    -- activations from the last fully connected layer of the deep convnet (VGG in this case)
    -- are passed through lti to get a vector of `embedding_size`
    -- linear layer dimensions are 4096 (size of fc7 layer) x `embedding_size`
    img.lti = nn.Sequential()
    img.lti:add(nn.Linear(4096, 24))
    img.lti:add(nn.Tanh())   --解决中
    img.lti:add(nn.Dropout(opt.dropout))


    -- protos.tan=nn.Sequential()  --修改
    -- protos.tan:add(nn.Tanh())  --解决中

    -- lstm: long short-term memory cell which takes a vector of size `embedding_size` at every time step
    -- 和上面的ltw说到的vector of size `embedding_size` 有关，回来解决
    -- hidden state h_t of LSTM cell in first layer is passed as input x_t of cell in second layer and so on.
    if opt.model == 'lstm' then
        print("we are doing LSTM")
        protos.lstm = LSTM.create(opt.embedding_size, opt.rnn_size, opt.num_layers) --看上去也没啥问题
    elseif opt.model == 'gru' then
        print("we are doing GRU")
        protos.lstm = GRU.create(opt.embedding_size, opt.rnn_size, opt.num_layers)
    elseif opt.model == 'rnn' then
        print("we are doing RNN")
        protos.lstm = RNN.create(opt.embedding_size, opt.rnn_size, opt.num_layers)
    end

    -- sm: linear layer + softmax over the answer vocabulary
    -- 要删去的，换成什么东西？？？...  改了a_vocab_size to q_vocab_size
    -- linear layer dimensions are `rnn_size` x `answer_vocab_size`
    protos.sm = nn.Sequential()
    -- print(loader.batch_data.train.nbatches * loader.batch_size)
    protos.sm:add(nn.Linear(opt.rnn_size, 24))   --loader.batch_data.train.nbatches * loader.batch_size  解决中


    -- negative log-likelihood loss
    -- protos.criterion = nn.ClassNLLCriterion()

    -- protos.criterion = nn.ParallelCriterion()
    -- directCriterion = nn.L1HingeEmbeddingCriterion(1)
    -- protos.criterion:add(directCriterion,1)

    protos.criterion = nn.L1HingeEmbeddingCriterion(1)  --测试
    -- Creates a criterion that measures the loss given an input x = {x1, x2}, 
    -- a table of two Tensors, and a label y (1 or -1): this is used for measuring 
    -- whether two inputs are similar or dissimilar, using the L1 distance, and is 
    -- typically used for learning nonlinear embeddings or semi-supervised learning.

    -- pass over the model to gpu
    if opt.gpuid >= 0 then
        protos.ltw = protos.ltw:cuda()
        img.lti = img.lti:cuda()
        protos.lstm = protos.lstm:cuda()
        protos.sm = protos.sm:cuda()
        -- protos.tan = protos.tan:cuda() 修改
        protos.criterion = protos.criterion:cuda()
    end

-- print("Initialize network parameters from checkpoint at this path done.....")
end

-- put all trainable model parameters into one  parameters tensor  参数在这里放进去了耶，注意！
params, grad_params = utils.combine_all_parameters(img.lti, protos.lstm, protos.sm)  --(img.lti, protos.lstm, protos.sm) 解决中

print('Parameters: ' .. params:size(1))
print('Batches: ' .. loader.batch_data.train.nbatches)


-- initialize model parameters
if do_random_init then
    params:uniform(-0.08, 0.08)
    -- print("initialize model parameters done.....")
end

-- make clones of the LSTM model that shared parameters for subsequent timesteps (unrolling)
-- q_max_length要解决  暂时解决
lstm_clones = {}
lstm_clones = utils.clone_many_times(protos.lstm, loader.q_max_length + 1)

-- print("lstm model clones done......")

-- initialize h_0 and c_0 of LSTM to zero tensors and store in `init_state`    应该不用改
init_state = {}
for L = 1, opt.num_layers do
    local h_init = torch.zeros(opt.batch_size, opt.rnn_size)
    h_init = h_init:cuda() 
    table.insert(init_state, h_init:clone())

    if opt.model == 'lstm' then
        table.insert(init_state, h_init:clone())
    end
end

-- print("initialize h_0 and c_0 of LSTM to zero tensors and store in init_state")

-- make a clone of `init_state` as it's going to be modified later   应该不用改
local init_state_global = utils.clone_list(init_state)
-- print('make a clone of init_state as it is going to be modified later')
    res = 0
    hmd = torch.Tensor(opt.batch_size,opt.batch_size)
-- closure to calculate accuracy over validation set
feval_val = function(max_batches)
	print("snapshots")
    count = 0
    n = loader.batch_data.val.nbatches
    -- print(n)
    -- set `n` to `max_batches` if provided
    if max_batches ~= nil then n = math.min(n, max_batches) end
    -- print(n)
    -- set to evaluation mode for dropout to work properly
    protos.ltw:evaluate()  -- evaluate = This sets the mode of the Module (or sub-modules) to train=false. 
    img.lti:evaluate()     -- This is useful for modules like Dropout or BatchNormalization that have a different
                           -- behaviour during training vs evaluation.
	-- print('set to evaluation mode for dropout to work properly')



    for i = 1, n do

        -- load question batch, answer batch and image features batch
        q_batch, a_batch, i_batch = loader:next_batch('val')

        -- 1st index of `nn.LookupTable` is reserved for zeros
        q_batch = q_batch + 1

        -- forward the question features through ltw
        qf = protos.ltw:forward(q_batch)   --load下一个batch


        -- forward the image features through lti  fully connected layer 
        imf = img.lti:forward(a_batch)  --i_batch

        -- convert to CudaTensor if using gpu  
        if opt.gpuid >= 0 then
            imf = imf:cuda()
        end

        -- set the state at 0th time step of LSTM
        rnn_state = {[0] = init_state_global}
		-- print('set the state at 0th time step of LSTM')
        -- LSTM forward pass for question features
        for t = 1, loader.q_max_length do
            lst = lstm_clones[t]:forward{qf:select(2,t), unpack(rnn_state[t-1])}  
            -- 解决中 把所有lstm结果加一起？...
            -- at every time step, set the rnn state (h_t, c_t) to be passed as input in next time step
            rnn_state[t] = {}
            for i = 1, #init_state do       --        table.insert(init_state, h_init:clone())
                table.insert(rnn_state[t], lst[i]) 
            end
        end
		-- print('LSTM forward pass for question features')
        -- after completing the unrolled LSTM forward pass with question features, forward the image features
        
        -- lst = lstm_clones[loader.q_max_length + 1]:forward{imf, unpack(rnn_state[loader.q_max_length])}
		-- print('after completing the unrolled LSTM forward pass with question features, forward the image features')
        -- 解决方法

        -- forward the hidden state at the last time step to get softmax over answers
        prediction = protos.sm:forward(lst[#lst])  --需要解决 写一个prediction over所有图片？ 200*99800   tanh过为什么会不是-1～1？？？
		-- print('forward the hidden state at the last time step to get softmax')
        -- count number of correct answers

        -- imf = imf:max(2):select(2,1)

        sp = prediction:storage()

        for i=1, sp:size() do
            if sp[i] <= 0 then
                sp[i] = 0
            else
                sp[i] = 1
            end
        end

        si = imf:storage()
        
        -- binary code ?
        for i=1, si:size() do
            if si[i] <= 0 then
                si[i] = 0
            else
                si[i] = 1
            end
        end



        for j = 1, opt.batch_size do
            idx  = 0
            for idx = 1, opt.batch_size do
                hmd[j][idx] = 0
                for i =1, 24 do
                    if prediction[j][i] ~= imf[j][i] then
                        hmd[j][idx] = hmd[j][idx] + 1
                    end
                end
            end

            hmd[j] = hmd[j]:sort()
            
            res = res + (1/hmd[j][1] + 2/hmd[j][2] + 3/hmd[j][3] + 4/hmd[j][4] + 5/hmd[j][5])/5
            print(res)


        end

        --先不管，看要不要解决

    end

    -- set to training mode once done with validation
    protos.ltw:training()
    print("ltw training")
    img.lti:training()
    print("lti training")

    -- return accuracy
    return res / (n * opt.batch_size)

end

-- closure to run a forward and backward pass and return loss and gradient parameters  
feval = function(x)

    -- get latest parameters
    if x ~= params then
        params:copy(x)
    end
    grad_params:zero()

    -- load question batch, image features batch and image id batch
    q_batch, a_batch, i_batch = loader:next_batch()   
    --annotations, image_features, image labels

    -- slightly hackish; 1st index of `nn.LookupTable` is reserved for zeros
    q_batch = q_batch + 1
    -- print(q_batch)
    -- 200 * 57

    -- forward the question features through ltw
    qf = protos.ltw:forward(q_batch)
    -- print(qf)    
    -- 200 * 57 * 256
    -- print ("------------------------")

    -- forward the image features through lti
    imf = img.lti:forward(a_batch) --i_batch

    -- convert to CudaTensor if using gpu
    imf = imf:cuda()

    si = imf:storage()
    
    -- binary code 
    for i=1, si:size() do
        if si[i] <= 0 then
            si[i] = 0
        else
            si[i] = 1
        end
    end
    
    -- print('-----------------------imf------------------')
    -- print(imf:narrow(1,2,50))

    ------------ forward pass ------------

    -- set initial loss
    loss = 0

    -- set the state at 0th time step of LSTM
    rnn_state = {[0] = init_state_global}
    -- LSTM forward pass for annotations
    for t = 1, loader.q_max_length do
        lstm_clones[t]:training()
        lst = lstm_clones[t]:forward{qf:select(2,t), unpack(rnn_state[t-1])}   --question feature, initial state
--  tensor like:
--                           t-1      t     t+1
--        I       am          |       |      
--       There   are          |       |  
--        It      is          |       |
--       Here    are          |       |
--       The    total         |       |

        -- at every time step, set the rnn state (h_t, c_t) to be passed as input in next time step
        -- print(lst)
        ---
        -- {
        --   1 : CudaTensor - size: 200x256     size of embeddings
        --          [torch.CudaTensor of size 200x256]
        --   2 : CudaTensor - size: 200x256
        --   3 : CudaTensor - size: 200x256
        --   4 : CudaTensor - size: 200x256
        -- }
        ---
        rnn_state[t] = {}
        for i = 1, #init_state do   -- table.insert(init_state, h_init:clone())
            table.insert(rnn_state[t], lst[i]) 
        end

    end

    -- print(unpack(rnn_state[loader.q_max_length])) --200*256
    
    -- lst = lstm_clones[loader.q_max_length + 1]:forward{imf,unpack(rnn_state[loader.q_max_length])}

    -- 解决中
    

    -- print(lst)
    -- print(loader.q_vocab_size)   30201
    -- print(loader.q_max_length)  57
    -- print(lst[1]:size())  200*512
    -- print(#lst)  
    -- forward the hidden state at the last time step to get softmax over features
    -- print(lst[#lst])
    prediction = protos.sm:forward(lst[#lst])  -- prediction  = 200*24?
    -- print(prediction)
    -- 可能有问题待解决

    -- calculate loss
    -- imf = imf:max(2):select(2,1)
    -- print(imf:size()) 200*1
    -- loss = protos.criterion:forward(prediction, imf)  --a_batch

    -- 测试
    sp = prediction:storage()

    for i=1, sp:size() do
        if sp[i] <= 0 then
            sp[i] = 0
        else
            sp[i] = 1
        end
    end

    -- print('----------------sp --------------')
    -- print(prediction:narrow(2,2,50))

    loss = protos.criterion:forward({prediction, imf}, i_batch )  --测试 20161031
    ------------ backward pass ------------

    -- backprop through loss and softmax
    -- print("in backpropagation through loss and softmax")

    -- dloss = protos.criterion:backward(prediction,imf)
    dloss = protos.criterion:backward({prediction, imf}, i_batch )  --a_batch  测试 20161031
    -- print(dloss:size())   --200*99800
    -- print(dloss[1])
    doutput_t = protos.sm:backward(lst[#lst], dloss[1]) --需要解决

    if opt.model == 'lstm' then
        num = 2
    else
        num = 1
    end
    -- set internal state of LSTM (starting from last time step)
    drnn_state = {[loader.q_max_length] = utils.clone_list(init_state, true)}  --q_max_length + 1 解决中
    drnn_state[loader.q_max_length][opt.num_layers * num] = doutput_t   --q_max_length + 1 解决中
    -- print("set internal state of LSTM done.....")

    -- backprop for last time step (image features)
--  dlst = lstm_clones[loader.q_max_length + 1]:backward({imf, unpack(rnn_state[loader.q_max_length])}, drnn_state[loader.q_max_length + 1])
    --q_max_length + 1 解决中
    dlst = lstm_clones[loader.q_max_length]:backward({qf:select(2, loader.q_max_length), unpack(rnn_state[loader.q_max_length-1])}, drnn_state[loader.q_max_length])
    -- print("backprop for last time step done.....")
    

    -- backprop into image linear layer
    -- 解决中
    -- img.lti:backward(a_batch, dlst[1]) --i_batch
    -- print("backprop into image linear layer done.....")

    -- set LSTM state
    drnn_state[loader.q_max_length-1] = {}
    for i,v in pairs(dlst) do
        if i > 1 then
            drnn_state[loader.q_max_length-1][i-1] = v
        end
    end
    -- print("set LSTM state done....")
    -- 解决中

    dqf = torch.Tensor(qf:size()):zero()
    if opt.gpuid >= 0 then
        dqf = dqf:cuda()
    end

    -- backprop into the LSTM for rest of the time steps
    for t = loader.q_max_length-1, 1, -1 do
        dlst = lstm_clones[t]:backward({qf:select(2, t), unpack(rnn_state[t-1])}, drnn_state[t])
        dqf:select(2, t):copy(dlst[1])
        drnn_state[t-1] = {}
        for i,v in pairs(dlst) do
            if i > 1 then
                drnn_state[t-1][i-1] = v
            end
        end
    end

    -- print(dqf)
    -- zero gradient buffers of lookup table, backprop into it and update parameters
    protos.ltw:zeroGradParameters()
    protos.ltw:backward(q_batch, dqf)
    protos.ltw:updateParameters(opt.learning_rate)

    -- clip gradient element-wise
    grad_params:clamp(-5, 5)


    return loss, grad_params

end

-- function gradUpdate(nwk, x1, x2, y, criterion, learningRate)
-- -- local pred = mlp:forward(x)
-- local err = criterion:forward(x2, y)
-- local gradCriterion = criterion:backward(x2, y)
-- nwk:zeroGradParameters()
-- nwk:backward(x1, gradCriterion)
-- nwk:updateParameters(learningRate)
-- end







-- optim state with ADAM parameters  
local optim_state = {learningRate = opt.learning_rate, alpha = opt.alpha, beta = opt.beta, epsilon = opt.epsilon}

-- train / val loop!
losses = {}
iterations = opt.max_epochs * loader.batch_data.train.nbatches
print('Max iterations: ' .. iterations)
lloss = 0

for i = 1, iterations do

    _, local_loss = optim.adam(feval, params, optim_state)


    losses[#losses + 1] = local_loss[1]

    lloss = lloss + local_loss[1]
    local epoch = i / loader.batch_data.train.nbatches

    if i%10 == 0 then
        print('epoch ' .. epoch .. ' loss ' .. lloss / 10)
        lloss = 0
    end

    -- Decay learning rate occasionally
    if i % loader.batch_data.train.nbatches == 0 and opt.learning_rate_decay < 1 then
        if epoch >= opt.learning_rate_decay_after then
            local decay_factor = opt.learning_rate_decay
            optim_state.learningRate = optim_state.learningRate * decay_factor -- decay it
            print('decayed learning rate by a factor ' .. decay_factor .. ' to ' .. optim_state.learningRate)
        end
    end

    -- Calculate validation accuracy and save model snapshot
    if i % opt.save_every == 0 or i == iterations then
        print('Checkpointing. Calculating validation accuracy..')
        -- local val_acc = feval_val()
        local val_acc = 666
        local savefile = string.format('%s/%s_epoch%.2f_%.4f.t7', opt.checkpoint_dir, opt.savefile, epoch, val_acc)
        print('Saving checkpoint to ' .. savefile)
        local checkpoint = {}
        checkpoint.opt = opt
        checkpoint.protos = protos
        checkpoint.vocab_size = loader.q_vocab_size
        torch.save(savefile, checkpoint)
    end

    if i%10 == 0 then
        collectgarbage()
    end
end
