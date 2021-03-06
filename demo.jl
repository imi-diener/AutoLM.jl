using AutoLandmarking
using Flux
using CuArrays # to run models on the GPU for massive performance increase
import ImageView

push!(LOAD_PATH, Base.@__DIR__)

# Import data with custom import functions
image_data, imname = load_imgs("C:/Users/immanueldiener/Desktop/Master/scripts/no_enamel", (128,128,128), false)
landmark_data = read_landmarks("C:/Users/immanueldiener/Desktop/Master/scripts/no_enamel", 10, "@1")

# X and Y coordinates are swapped in avizo files, wo I'll swap them back here.
#this step is essential for all the data augmentation to work.
landmark_data = swap_xy(landmark_data)

#some images have a higher value in the fill voxels than in the actual object voxels. This will fix the issue.
# The highest value must always be the filler value!
image_data[:,:,:,[109,130]] = image_data[:,:,:,[109,130]] .- 1
image_data[:,:,:,[109,130]] = image_data[:,:,:,[109,130]] .* -1

image_data2, imname2 = load_imgs("C:/Users/immanueldiener/Desktop/Master/master_data\\additional_teeth_volumes\\", (128,128,128), true)
landmark_data2 = read_landmarks("C:/Users/immanueldiener/Desktop/Master/master_data\\additional_teeth_volumes\\", 10, "@1")

#Swap X and Y again
landmark_data2 = swap_xy(landmark_data2)

#all these images have reversed fill and object values. Tha highest value must always be the filler value!
image_data2 = (image_data2 .- 1) .* -1

names = vcat(imname, imname2)
images = cat(image_data, image_data2, dims=4)
lms = cat(landmark_data, landmark_data2, dims=2)

# align along principal axes
aligned, aligned_lms, retro = align_principal(images, lms, 192)
resized, resized_lms, scales = resize_relevant(aligned, aligned_lms, 144)
ImageView.imshow(depth_map_all_sides(resized))
#define training and testing sets
X_train, X_test, y_train, y_test = regular_train_test_split_3d(resized, resized_lms)

# perform data augmentation. In case of RAM limitations the depth-map generation can be
# done right after every augmentation step, after which the augmented volumes can be deleted.
X_train, y_train = (mirror_vol(X_train, y_train))

X_train = Float32.(X_train)

flip1, lm_flip1 = flip_3D(X_train, y_train)
flip2, lm_flip2 = flip_volume_front(flip1, lm_flip1)
flip3, lm_flip3 = flip_volume_side(flip2, lm_flip2)

rot, lm_rot = rotate_volumes(flip2, lm_flip2, 10)
rot2, lm_rot2 = rotate_volumes(X_train, y_train, 20)
rot3, lm_rot3 = rotate_volumes(flip3, lm_flip3, -15)

jit, lm_jit = jitter_3D(flip1, lm_flip1, 10)
jit2, lm_jit2 = jitter_3D(X_train, y_train, 10)
jit3, lm_jit3 = jitter_3D(flip3, lm_flip3, 10)
jit4, lm_jit4 = jitter_3D(rot2, lm_rot2, 10)


complete1 = depth_map_all_sides(X_train)
X_train=nothing
complete2 = depth_map_all_sides(flip1)
flip1=nothing
complete3 = depth_map_all_sides(flip2)
flip2=nothing
complete4 = depth_map_all_sides(flip3)
flip3=nothing
complete5 = depth_map_all_sides(rot)
rot=nothing
complete6 = depth_map_all_sides(rot2)
rot2=nothing
complete7 = depth_map_all_sides(rot3)
rot3=nothing
complete8 = depth_map_all_sides(jit)
jit=nothing
complete9 = depth_map_all_sides(jit2)
jit2=nothing
complete10 = depth_map_all_sides(jit3)
jit3=nothing
complete11 = depth_map_all_sides(jit4)

X_train = cat(complete1, complete2, complete3, complete4, complete5, complete6,
    complete7, complete8, complete9, complete10, complete11, dims=4)
y_train = cat(y_train, lm_flip1, lm_flip2, lm_flip3, lm_rot, lm_rot2, lm_rot3, lm_jit, lm_jit2, lm_jit3, lm_jit4, dims=2)

X_train = image_gradients(X_train)

# make depthmaps of the testing data
X_test = depth_map_all_sides(X_test)
X_test = image_gradients(X_test)

# define the cost function
cost(x, y) = sum((model(x)-y).^2)|>gpu

#define the model
model = Flux.mapleaves(cu, AutoLandmarking.vgg19)

# define the trainingrate and optimiser
opt = Flux.ADAM(0.00003)

# redefinition of the dropout function to work with testmode!() since this
# functionality is not working at the moment. This step only needs to be done
# if you wish to perform uncertainty estimation using the dropout method (AutoLM.response_distribution())
# after training.
using Random
function Flux.dropout(x, p; dims = :)
    q = 1 - p
    y = rand!(similar(x, Flux._dropout_shape(x, dims)))
    y .= Flux._dropout_kernel.(y, p, q)
    x .* y
end

import Zygote
Zygote.@adjoint function Flux.dropout(x, p; dims = :)
   q = 1 - p
   y = rand!(similar(x, Flux._dropout_shape(x, dims)))
   y .= Flux._dropout_kernel.(y, p, q)
   return x .* y, Δ -> (Δ .* y, nothing)
end
Zygote.refresh()

function run_model(modell, X, y)
  train_data = Flux.mapleaves(cu, X)
  train_labels = Flux.mapleaves(cu, y)
  dataset = Flux.Data.DataLoader(train_data, train_labels, batchsize = 4, shuffle=true)
  Flux.train!(cost, params(model), dataset, opt)
  testmode!(model)
  cosima = cost_whole_data_2D(train_data, train_labels, cost)
  testmode!(model, false)
  return cosima
end


# create lists to store metrics
accs = []
costs = []

# run the training for 300 epochs. batches of 128 will be loaded onto the GPU,
# which will be further subdevided into minibatches of 4 (as defined in AutoML.run_model).
for i in 1:400
  costr = 0
  for j in 1:128:size(X_train, 4)
    if j+127 > size(X_train, 4)
      train_data = X_train[:,:,:,j:end]
      train_labels = y_train[:,j:end]
    else
      train_data = X_train[:,:,:,j:j+127]
      train_labels = y_train[:,j:j+127]
    end
    cosima = run_model(model, train_data, train_labels)
    costr = costr + cosima
    train_data = nothing
    train_labels = nothing
    # GC.gc()
  end
  push!(costs, costr)
  println("epoch ", i, " finished")
  println(costr)
  testmode!(model)
  acc2, max1, min1 = AutoLandmarking.avg_accuracy_per_point(model, gpu(X_test[:,:,:,:]), gpu(y_test[:,:]), 3)
  testmode!(model, false)
  println("median deviation per point on testing dataset: ", acc2, "with maximum", max1)
  println("median sum is ", sum(acc2))
  push!(accs, sum(acc2))
  if sum(acc2)[1]<7.6
    break
  end
end


#save model
using BSON
testmode!(model) #save the model in testmode so that the dropout layers are inactive!
model_cpu = cpu(model)
BSON.@save "C:/Users/immanueldiener/Desktop/Master/master_data/model_teeth.bson" model_cpu

#load model back in
BSON.@load "C:/Users/immanueldiener/Desktop/Master/master_data/model_teeth.bson" model_cpu
model = gpu(model_cpu)



# ================== After training ===================


#solve issue with arrays inside vector
aks = []
for i in accs
  push!(aks, i[1])
end

# check what the best accuracy is
minimum(aks)

#plot the development of cost and accuracy
import Plots
Plots.plot(aks, legend=:topright, label="sum of deviations per point", color= :red, xlabel="epochs", ylabel = "acuracy")
plt = Plots.plot!(Plots.twinx(), costs, label="training loss", legend=:topleft, ylabel = "loss")

# check for outliers (greatest distance from the procrustes mean).
# teh idea is to eliminate out all the predicted landmark sets that
# deviate a lot from the procrustes mean (reference), since these are
# most likely bad predictions. do get the procrustes mean, we can use training
# testing data together to get a more accureate mean. This is an ideal approch
# because otherwise we would not realize if all the predictions are biased in some
# way that is congruent over all predictions but still wrong.

function print_costs(y, resp)
  costs=[]
  for i in 1:size(resp,2)
    dev = sum((y[:,i] .- resp[:,i]) .^2)
    push!(costs, dev)
    println(i, "    ", dev)
  end
  return costs
end

X_train2, X_test2, y_train2, y_test2 = regular_train_test_split_3d(images, lms) #to get the volumes again

response = cpu(predict_set(gpu(X_test), model)) #predictions

# translate predictions back to the original volumes and get the names for training
# and testing set. This is necessary since we performed PC-alignment and resizing before training.
retro_test = zeros(3,5,48)
scales_test = zeros(1,48)
names_test = []
names_train = []
for i in 1:48
  push!(names_test, names[i*5])
  retro_test[:,:,i] = retro[:,:,i*5]
  scales_test[1,i] = scales[i*5]
end
for i in 1:243
  if i%5!=0
    push!(names_train, names[i])
  end
end

response_scaled = deepcopy(response)

for i in 1:48
  response_scaled[:,i] .= response[:,i]./scales_test[i]
end

accuracies = []
for i in 1:48
  acc2, max1, min1 = AutoLandmarking.avg_accuracy_per_point(model, gpu(X_test[:,:,:,i:i]), gpu(y_test[:,i:i]), 3)
  push!(accuracies, sum(acc2))
  println(i, "   ", sum(acc2))
end

# set negative values to 0 and values outside the volume to the maximum along each dimension
response_unaligned = relu.(translate_lms_back(response_scaled, retro_test))
AutoLandmarking.change_values!(response_unaligned, 12.8, 12.8, >)

# put landmarks near the surface onto the surface and look at the cost change
response_on_vol = landmark_to_surface(X_test2, response_unaligned, 10)
costs = print_costs(y_test2, response_on_vol) # using the landmark_to_surface function is useful

#outlier detection based on procrustes distances

three_d_train = AutoLandmarking.to_3d_array(y_train2)
three_d_test = AutoLandmarking.to_3d_array(response_on_vol)

aligned_train = AutoLandmarking.align_all(three_d_train)
aligned_test = AutoLandmarking.align_all(three_d_test)

mean_train, stdevs = AutoLandmarking.mean_shape(aligned_train)

distances = AutoLandmarking.proc_distance(mean_train, aligned_test, stdevs)
dists = []
for i in 1:48
  push!(dists, distances[i])
end

# look at distances from mean and respective costs
for i in 1:48
  println("ind $i cost is ", costs[i], "  and dist is ", dists[i])
end

# outlier detection based on model uncertainty using the response_distribution function
uncertainties = []
for i in 1:48
  means, stddev = AutoLandmarking.response_distribution(model, gpu(X_test[:,:,:,i:i]), gpu(y_test[:,i:i]), 200)
  println("$i has uncevertaty", sum(stddev), "  and cost  ", costs[i])
  push!(uncertainties, sum(stddev))
end
