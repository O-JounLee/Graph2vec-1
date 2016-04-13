require 'torch'
require 'nn'
require 'optim'
require 'math'
require 'os'
require 'sys'

print('Reading nodes...')
local vocab = {}
for line in io.lines("../BlogCatalog-dataset/datatemp/nodes.csv") do
	local u = line
	vocab[#vocab+1] = {u=torch.Tensor{u}}
end

num_edges = 0

print('Reading edges...')
local graph = {}
for line in io.lines("../BlogCatalog-dataset/datatemp/edges.csv") do
	local u,v = line:match("([^,]+),([^,]+)")
	u = tonumber(u)
	v = tonumber(v)
	if graph[u] == nil then
		graph[u] = {}
	end
	graph[u][#graph[u]+1] = v
	num_edges = num_edges + 1
end


print('Calc Out_Degree')
Out_Degree = {}
for i=1, #vocab do
	if graph[i] == nil then
		Out_Degree[i] = 0
	else
		Out_Degree[i] = #graph[i]
	end
end





--for i=1, #graph do
--	graph[i]['w'] = torch.Tensor{1/#graph}
--	graph[i]['s'] = torch.Tensor{1/Out_Degree[graph[i]['u'][1]]}
--end


context = {}
for i =1,10 do
	context[i] = 0
end

print('data preprocessing done.!!')

vocab_size = #vocab
node_embed_size = 5
learning_rate = 0.01
max_epochs = 10
batch_size = 1000
num_neg_samples = 5
neg_sample_lookup_size = 1e6
neg_sample_lookup = torch.IntTensor(neg_sample_lookup_size)

criterion = nn.DistKLDivCriterion()
edge_batch = {}
function edge_batch:size() return #edge_batch end

-- #############################################################################################################

function build_table()
    local start = sys.clock()
    local total_count_pow = 0
    print("Building the negative sampling table... ")
    for i = 1, vocab_size do
    	total_count_pow = total_count_pow + Out_Degree[i]^0.75
    end

    -- Negative samples lookup table
    local word_index = 1
    local word_prob = Out_Degree[word_index]^0.75 / total_count_pow
    for idx = 1, neg_sample_lookup_size do
        neg_sample_lookup[idx] = word_index
        if idx / vocab_size > word_prob then
            word_index = word_index + 1
            if word_index > vocab_size then
            	word_index = word_index - 1
        	end
	    	word_prob = word_prob + Out_Degree[word_index]^0.75 / total_count_pow
        end
    end
    print('Negative sampling table done..')
end


function generate_neg_samples(node)     -- NEEDS TO BE UPDATED
    local i = 1
    while i <= num_neg_samples do
        neg_context = neg_sample_lookup[torch.random(neg_sample_lookup_size)]
		if neg_context ~= node then
			--context[i] = torch.Tensor{neg_context}
	    	context[i] = torch.Tensor{neg_context}
	    	i = i + 1
		end
    end
end

-- Populate Neg_Sample_Lookup table
build_table()


train_data_FOP = {}
train_data_SOP = {}
print('Populating training data..')

i = 1
batch_FOP = {}
batch_SOP = {}
k=1
while i <= #vocab do
	if graph[i] ~= nil then
		for j=1, #graph[i] do
			local features_FOP = {torch.Tensor{i},torch.Tensor{graph[i][j]}}
 			local label_FOP = torch.Tensor{1/num_edges}
 			batch_FOP[k] = {features_FOP,label_FOP}

 			local u = i
			local v = graph[i][j]
			generate_neg_samples(u)
			local features_SOP = {{torch.Tensor{v},torch.Tensor{u}}}
			features_SOP[2] = {context,torch.Tensor{u}}
 			local label_SOP = torch.Tensor{1/Out_Degree[i]}
 			batch_SOP[k] = {features_SOP,label_SOP}

 			k = k+1
 			if k > batch_size then
 				train_data_FOP[#train_data_FOP+1] = batch_FOP
 				train_data_SOP[#train_data_SOP+1] = batch_SOP
 				batch_FOP = {}
 				batch_SOP = {}
 				k=1
 			end
 		end
 	end
 	i = i + 1
 	print(i)
end

if k<=batch_size then
	train_data_FOP[#train_data_FOP+1] = batch_FOP
	train_data_SOP[#train_data_SOP+1] = batch_SOP
end

print('Done!')
print(#train_data_FOP)
print(#train_data_SOP)



function train_data_FOP:size() return #train_data_FOP end


node_lookupR = nn.LookupTable(vocab_size, node_embed_size)

model_FOP = nn.Sequential()
model_FOP:add(nn.ParallelTable())
model_FOP.modules[1]:add(node_lookupR)
model_FOP.modules[1]:add(node_lookupR:clone('weight', 'bias', 'gradWeight', 'gradBias'))
model_FOP:add(nn.DotProduct())
model_FOP:add(nn.Sigmoid())





params, grad_params = model_FOP:getParameters()

feval = function(x)
	-- Get new params
	params:copy(x)

	-- Reset gradients (buffers)
	grad_params:zero()

	-- loss is average of all criterions
	local loss = 0
	for i = 1, #edge_batch do
		local output = model_FOP:forward(edge_batch[i][1])
		loss = loss + criterion:forward(output, edge_batch[i][2])
		local grads = criterion:backward(output, edge_batch[i][2])
		model_FOP:backward(edge_batch[i][1], grads)
	end
	grad_params:div(#edge_batch)

	return loss, grad_params
end

optim_state = {learningRate = learning_rate}
print('# StochasticGradient Part-1: training')
local l = 0
for epoch = 1, max_epochs do
	for i=1, #train_data_FOP do
		edge_batch = train_data_FOP[i]
		local _, loss = optim.sgd(feval, params, optim_state)
		l = loss[1]
	end
	print('# current error = '..l)
end
-- print('\nNode Lookup after learning')
-- print(node_lookup.weight)

-- #############################################################################################################--
--

-- print(#train_data_SOP)

-- Building neural network (Second-Order proximity)

node_lookupC = nn.LookupTable(vocab_size, node_embed_size)
-- node_lookupR = nn.LookupTable(vocab_size, node_embed_size)

model2 = nn.Sequential()
model2:add(nn.ParallelTable())
model2.modules[1]:add(node_lookupC)
model2.modules[1]:add(node_lookupR)
model2:add(nn.DotProduct())
model2:add(nn.LogSigmoid())


model4 = nn.Sequential()
model4:add(nn.ParallelTable())
for k =1, num_neg_samples  do
	model4.modules[1]:add(node_lookupC)
end
model4:add(nn.JoinTable(1))


model3 = nn.Sequential()
model3:add(nn.ParallelTable())
model3.modules[1]:add(model4)

model3.modules[1]:add(node_lookupR)
model3:add(nn.MM(false,true))
model3:add(nn.MulConstant(-1,true))
model3:add(nn.LogSigmoid())
model3:add(nn.Sum())


model = nn.Sequential()
model:add(nn.ParallelTable())
model.modules[1]:add(model2)
model.modules[1]:add(model3)
model:add(nn.DotProduct())



-- input = {{torch.Tensor{2},torch.Tensor{3}},{{torch.Tensor{4},torch.Tensor{4},torch.Tensor{4},torch.Tensor{4},torch.Tensor{4},torch.Tensor{4},torch.Tensor{4},torch.Tensor{4},torch.Tensor{4},torch.Tensor{4}},torch.Tensor{2}}}
-- print(model:forward(input))









params, grad_params = model:getParameters()

feval2 = function(x)
	-- Get new params
	params:copy(x)

	-- Reset gradients (buffers)
	grad_params:zero()

	-- loss is average of all criterions
	local loss = 0
	for i = 1, #edge_batch do
		local output = model:forward(edge_batch[i][1])
		loss = loss + criterion:forward(output, edge_batch[i][2])
		local grads = criterion:backward(output, edge_batch[i][2])
		model:backward(edge_batch[i][1], grads)
	end
	grad_params:div(#edge_batch)

	return loss, grad_params
end

optim_state = {learningRate = learning_rate}
print('# StochasticGradient Part-2: training')
local l = 0
for epoch = 1, max_epochs do
	for batch=1, #train_data_SOP do
		edge_batch = train_data_SOP[batch]
		local _, loss = optim.sgd(feval2, params, optim_state)
		l = loss[1]
	end
	print('# current error = '..l)
end


print('\nNode Lookup after learning')

print(node_lookupR.weight)
torch.save("temp.dat", node_lookupR.weight)



