module MXNet
  module Optimizer
    def self.registry_manager
      @registry_manager ||= MXNet::Registry::Manager.new(Base, :optimizer)
    end
    private_class_method :registry_manager

    def self.create(*args, **kwargs)
      registry_manager.create(*args, **kwargs)
    end

    module Registry
      @opt_registry = {}

      # Registers a new optimizer.
      #
      # Once an optimizer is registered, we can create an instance of this
      # optimizer with `Optimizer[name].new` later.
      def register(klass)
        unless klass < MXNet::Optimizer::Base
          raise ArgumentError, "optimizer must be a subclass of MXNet::Optimizer::Base"
        end
        name = self.name[/::([^:]+)\z/, 1].downcase.to_sym
        if @opt_registry.has_key? name
          warn "WARNING: New optimizer #{self} is overriding existing " +
              "optimizer #{@opt_registry[name]}"
        end
        @opt_registry[name] = self
      end

      def [](name)
        @opt_registry[name.downcase.to_sym] or
          raise KeyError, "Cannot find optimizer #{name}"
      end
    end

    # The base class inherited by all optimizers.
    #
    # Custom optimizers can be created by subclassing MXNet::Optimizer::Base
    # and implementing the required function #update. By default, the created
    # optimizer will be registered under its simplified class name
    # (`class.name.split('::').last.downcase.to_sym`) but it may be registered
    # under another name by calling MXNet::Optimizer.register.
    #
    #     class MyOptimizer < Optimizer
    #       def update(index, weight, gradient, state)
    #         ...
    #       end
    #     end
    #     register MyOptimizer, :myopt
    #
    class Base
      # Creates a new instance.
      #
      # ====Parameters
      #
      # +rescale_grad+::  (float, optional)
      #                   Before updating, multiply the gradient with
      #                   "rescale_grad". Often choose to be
      #                   <tt>1.0/batch_size</tt>.
      # +learning_rate+:: (float, optional)
      #                   The initial learning rate.
      # +wd+::            (float, optional)
      #                   The weight decay (or L2 regularization)
      #                   coefficient. Modifies objective by adding a
      #                   penalty for having large weights.
      #
      def initialize(rescale_grad: 1.0,
                     param_idx2name: nil,
                     wd: 0.0,
                     clip_gradient: nil,
                     learning_rate: 0.01,
                     lr_scheduler: nil,
                     sym: nil,
                     begin_num_update: 0,
                     multi_precision: false,
                     param_dict: nil)
        @rescale_grad = rescale_grad
        @lr = learning_rate
        @lr_scheduler = lr_scheduler
        @lr_scheduler.base_lr = learning_rate if @lr_scheduler

        @wd = wd
        @lr_mult = {}
        @wd_mult = {}
        @begin_num_update = begin_num_update
        @num_update = begin_num_update
        @index_update_count = {}
        @clip_gradient = clip_gradient
        @multi_precision = multi_precision

        param_idx2name ||= {}
        unless param_idx2name.is_a? Hash
          raise ArgumentError, "param_idx2name should be a Hash of param indexes to names."
        end
        @idx2name = param_idx2name.dup
        @sym_info = sym ? [sym.attr_dict, sym.list_arguments] : []
        @param_dict = param_dict || {}

        @lr_mult = {}
        @wd_mult = {}
      end

      attr_accessor :rescale_grad, :param_dict

      attr_reader :lr_scheduler

      def learning_rate
        if @lr_scheduler
          @lr_scheduler.(@num_update)
        else
          @lr
        end
      end

      # Sets a new learning rate of the optimizer.
      def learning_rate=(lr)
        if @lr_scheduler
          raise "LRScheduler of the optimizer has already been defined. " +
                "Note that learning_rate= can mutate the value of " +
                "the learning rate of the optimizer only when " +
                "the LRScheduler of the optimizer is undefined."
        else
          @lr = lr
        end
      end

      # Creates auxiliary state for a given weight.
      def create_state(index, weight)
        nil
      end

      # Creates auxiliary state for a given weight, including FP32 high
      # precision copy if original weight is FP16.
      #
      # This method is provided to perform automatic mixed precision training
      # for optimizers that do not support it themselves.
      def create_state_multi_precision(index, weight)
        weight_master_copy = nil
        if @multi_precision && weight.dtype == :float16
          weight_master_copy = weight.as_type(:float32)
          return [weight_master_copy, create_state(index, weight_master_copy)]
        end
        if weight.dtype == :float16 && !multi_precision
          warn "Accumulating with float16 in optimizer can lead to " +
               "poor accuracy or slow convergence. " +
               "Consider using multi_precision: true option of the optimizer"
        end
        create_state(index, weight)
      end

      # Updates the given parameter using the coressponding gradient and state.
      #
      # ====Parameters
      #
      # +index+::    (integer)
      #              The unique index of the parameter into the
      #              individual learning rates and weight
      #              decays. Learning rates and weight decay may be set
      #              via #set_lr_mult and #set_wd_mult, respectively.
      # +weight+::   (NDArray)
      #              The parameter to be updated.
      # +gradient+:: (NDArray)
      #              The gradient of the objective with respect to this
      #              parameter.
      # +state+::    (any)
      #              The state returned by #create_state.
      def update(index, weight, grad, state)
        raise NotImplementedError
      end

      # Updates the given parameter using the coressponding gradient and state.
      # Mixed precision version.
      def update_multi_precision(index, weight, grad, state)
        if @multi_precision && weight.dtype == :float16
          weight_master_copy = state[0]
          original_state = state[1]
          grad32 = grad.as_type(:float32)
          update(index, weight_master_copy, grad32, original_state)
          MXNet::NDArray.cast(weight, dtype: weight.dtype, out: weight)
        else
          update(index, weight, grad, state)
        end
      end

      # Sets an individual learning rate multiplier for each parameter.
      def lr_mult=(args_lr_mult)
        @lr_mult = {}
        if not @sym_info.empty?
          attrs, arg_names = @sym_info
          arg_names.each do |name|
            if attrs.has_key?(name) && attrs[name].has_key?(:__lr_mult__)
              @lr_mult[name] = Float(attrs[name][:__lr_mult__])
            end
          end
        end
        @lr_mult.update(args_lr_mult)
      end

      # Sets an individual weight decay multiplier for each parameter.
      def wd_mult=(args_wd_mult)
        @wd_mult = {}
        @idx2name.each_value do |n|
          @wd_mult[n] = 0.0 if n.end_with?('_weight') || n.end_with?('_gamma')
        end
        if not @sym_info.empty?
          attrs, arg_names = @sym_info
          arg_names.each do |name|
            if attrs.has_key?(name) && attrs[name].has_key?(:__wd_mult__)
              @wd_mult[name] = Float(attrs[name][:__wd_mult__])
            end
          end
        end
        @wd_mult.update(args_wd_mult)
      end

      # Updates num_update.
      private def update_count(index)
        @index_update_count[index] ||= @begin_num_update
        @index_update_count[index] += 1
        @num_update = [@index_update_count[index], @num_update].max
      end

      # Gets the learning rate given the index of the weight.
      #
      # ====Parameters
      #
      # +index+:: (integer)
      #           The index corresponding to the weight.
      #
      # ====Returns
      #
      # Learning rate for this index.
      private def get_lr(index)
        if @lr_scheduler
          lr = @lr_scheduler.(@num_update)
        else
          lr = @lr
        end

        if @param_dict.has_key? index
          lr *= @param_dict[index].lr_mult
        elsif @lr_mult.has_key? index
          lr *= @lr_mult[index]
        elsif @idx2name.has_key? index
          lr *= @lr_mult[@idx2name[index]] || 1.0
        end
        return lr
      end

      # Gets weight decay for index.
      # Returns 0 for non-weights if the name of weights are provided for `__init__`.
      #
      # ====Parameters
      #
      # +index+:: (integer)
      #           The index corresponding to the weight.
      #
      # ====Returns
      #
      # Weight decay for this index.
      private def get_wd(index)
        wd = @wd
        if @param_dict.has_key? index
          wd *= @param_dict[index].wd_mult
        elsif @wd_mult.has_key? index
          wd *= @wd_mult[index]
        elsif @idx2name.has_key? index
          wd *= @wd_mult[@idx2name[index]] || 1.0
        end
        return wd
      end

      # Gets the learning rates given the indices of the weights.
  
      # Parameters
      # ----------
      # +indices+:: list of integer
      #     Indices corresponding to weights.

      # Returns
      # -------
      # +lrs+:: list of float
      #     Learning rates for those indices.
      
      private def get_lrs(indices)
          
          if @lr_scheduler.nil?
            lr = @lr
          else
            lr = @lr_scheduler[@num_update]
          end

          lrs = indices.map{lr}

          indices.each_with_index do |index, i|
              if @param_dict.has_key? index
                  lrs[i] *= @param_dict[index].lr_mult
              elsif  @lr_mult.has_key? index
                  lrs[i] *= @lr_mult[index]
              elsif @idx2name.has_key? index
                  lrs[i] *= @lr_mult[@idx2name[index]] || 1.0
              end
          end

          lrs
      end
      
      # Gets weight decays for indices.
      # Returns 0 for non-weights if the name of weights are provided for `__init__`.

      # Parameters
      # ----------
      # +indices+:: list of int
      #     Indices of weights.

      # Returns
      # -------
      # +wds+:: list of float
      #     Weight decays for those indices.
      private def get_wds indices
        wds = indices.map {@wd}
        indices.each_with_index do |index, i|
          if @param_dict.has_key? index
              wds[i] *= @param_dict[index].wd_mult
          elsif @wd_mult.has_key? index 
              wds[i] *= @wd_mult[index]
          elsif @idx2name.has_key? index
              wds[i] *= @wd_mult[@idx2name[index]] || 1.0
          end
        end
        wds
      end

    end

    # The SGD optimizer with momentum and weight decay.
    class SGD < Base
      # Creates a new instance.
      #
      # This optimizer accepts the following parameters in addition to
      # those accepted by Optimizer.
      #
      # ====Parameters
      #
      # +momentum+:: (float, optional)
      #              The momentum value.
      def initialize(momentum: 0.0, lazy_update: true, **kwargs)
        super(**kwargs)
        @momentum = momentum
        @lazy_update = lazy_update
      end

      def create_state_multi_precision(index, weight)
        weight_master_copy = nil
        if @multi_precision && weight.dtype == :float16
          weight_master_copy = weight.as_type(:float32)
          return [create_state(index, weight_master_copy), weight_master_copy]
        end
        if weight.dtype == :float16 && !multi_precision
          warn "Accumulating with float16 in optimizer can lead to " +
               "poor accuracy or slow convergence. " +
               "Consider using multi_precision: true option of the SGD optimizer"
        end
        return create_state(index, weight)
      end

      def create_state(index, weight)
        momentum = nil
        # TODO: stype = @lazy_update ? weight.stype : :default
        if @momentum != 0.0
          momentum = MXNet::NDArray.zeros(weight.shape, weight.context, dtype: weight.dtype) # stype: stype
        end
        return momentum
      end

      private def update_impl(index, weight, grad, state, multi_precision: false)
        raise unless weight.is_a? NDArray
        raise unless grad.is_a? NDArray
        update_count(index)
        lr = get_lr(index)
        wd = get_wd(index)

        kwargs = { rescale_grad: @rescale_grad }
        kwargs[:momentum] = @momentum if @momentum > 0
        kwargs[:clip_gradient] = @clip_gradient if @clip_gradient

        if !multi_precision
          if state
            MXNet::NDArray.sgd_mom_update(weight, grad, state, out: weight, lr: lr, wd: wd, **kwargs)
          else
            MXNet::NDArray.sgd_update(weight, grad, out: weight, lr: lr, wd: wd, **kwargs)
          end
        else
          if state[0]
            MXNet::NDArray.mp_sgd_mom_update(weight, grad, state[0], state[1], out: weight, lr: lr, wd: wd, **kwargs)
          else
            MXNet::NDArray.mp_sgd_update(weight, grad, state[1], out: weight, lr: lr, wd: wd, **kwargs)
          end
        end
      end

      def update(index, weight, grad, state)
        update_impl(index, weight, grad, state, multi_precision: false)
        nil
      end

      def update_multi_precision(index, weight, grad, state)
        use_multi_precision = @multi_precision && weight.dtype == :float16
        update_impl(index, weight, grad, state, multi_precision: use_multi_precision)
        nil
      end
    end

    registry_manager.register SGD

    # The Signum optimizer that takes the sign of gradient or momentum.

    # The optimizer updates the weight by::

    #     rescaled_grad = rescale_grad * clip(grad, clip_gradient) + wd * weight
    #     state = momentum * state + (1-momentum)*rescaled_grad
    #     weight = (1 - lr * wd_lh) * weight - lr * sign(state)

    # References
    # ----------
    # Jeremy Bernstein, Yu-Xiang Wang, Kamyar Azizzadenesheli & Anima Anandkumar. (2018).
    # signSGD: Compressed Optimisation for Non-Convex Problems. In ICML'18.

    # See: https://arxiv.org/abs/1802.04434

    # For details of the update algorithm see
    # :class:`~mxnet.ndarray.signsgd_update` and :class:`~mxnet.ndarray.signum_update`.

    # This optimizer accepts the following parameters in addition to those accepted
    # by :class:`.Optimizer`.

    # Parameters
    # ----------
    # +momentum+:: float, optional
    #    The momentum value.
    # +wd_lh+:: float, optional
    #    The amount of decoupled weight decay regularization, see details in the original paper at:\
    #    https://arxiv.org/abs/1711.05101

    class Signum < Base
      def initialize learning_rate: 0.01, momentum: 0.9, wd_lh: 0.0, **kwargs
        super **kwargs
        
        @momentum = momentum
        @wd_lh = wd_lh
      end

      def create_state index, weight
        momentum = nil
        if @momentum != 0.0
          momentum = MXNet::NDArray.zeros(weight.shape, weight.context, dtype: weight.dtype)
        end

        momentum
      end

      

      def update index, weight, grad, state
          update_impl index, weight, grad, state
      end

      private def update_impl index, weight, grad, state
        raise unless weight.is_a? NDArray
        raise unless grad.is_a? NDArray
        update_count index
        lr = get_lr index
        wd = get_wd index

        kwargs = {rescale_grad: @rescale_grad}
        kwargs[:momentum] = @momentum if @momentum > 0
            
        kwargs[:clip_gradient] = @clip_gradient if @clip_gradient
            
        kwargs[:wd_lh] = @wd_lh if @wd_lh
            

        if state.nil?
          MXNet::NDArray.signsgd_update weight, grad, out: weight,
                         lr: lr, wd: wd, **kwargs
        else
          MXNet::NDArray.signum_update weight, grad, state, out: weight,
                        lr: lr, wd: wd, **kwargs
        end
      end
    end

    registry_manager.register Signum

    class FTML < Base
      # The FTML optimizer.
  
      # This class implements the optimizer described in
      # *FTML - Follow the Moving Leader in Deep Learning*,
      # available at http://proceedings.mlr.press/v70/zheng17a/zheng17a.pdf.
  
      # Denote time step by t. The optimizer updates the weight by::
  
      #     rescaled_grad = clip(grad * rescale_grad + wd * weight, clip_gradient)
      #     v = beta2 * v + (1 - beta2) * square(rescaled_grad)
      #     d_t = (1 - power(beta1, t)) / lr * square_root(v / (1 - power(beta2, t))) + epsilon)
      #     z = beta1 * z + (1 - beta1) * rescaled_grad - (d_t - beta1 * d_(t-1)) * weight
      #     weight = - z / d_t
  
      # For details of the update algorithm, see :class:`~mxnet.ndarray.ftml_update`.
  
      # This optimizer accepts the following parameters in addition to those accepted
      # by :class:`.Optimizer`.
  
      # Parameters
      # ----------
      # +beta1+:: float, optional
      #     0 < beta1 < 1. Generally close to 0.5.
      # +beta2+:: float, optional
      #     0 < beta2 < 1. Generally close to 1.
      # +epsilon+:: float, optional
      #     Small value to avoid division by 0.
      
      def initialize beta1: 0.6, beta2: 0.999, epsilon: 1e-8, **kwargs
        super **kwargs
        @beta1 = beta1
        @beta2 = beta2
        @epsilon = epsilon
      end
  
      def create_state index, weight
          [zeros(weight.shape, weight.context, dtype: weight.dtype), # d_0
           zeros(weight.shape, weight.context, dtype: weight.dtype), # v_0
           zeros(weight.shape, weight.context, dtype: weight.dtype)] # z_0
      end
  
      def update index, weight, grad, state
        raise unless weight.is_a? MXNet::NDArray
        raise unless grad.is_a? MXNet::NDArray
        update_count(index)
        lr = get_lr(index)
        wd = get_wd(index)
        t = @index_update_count[index]

        kwargs = {beta1: @beta1, beta2: @beta2, epsilon: @epsilon,
                  rescale_grad: @rescale_grad, t: t}
        
        kwargs[:clip_grad] = @clip_gradient if @clip_gradient
        
        prev_d, prev_v, prev_z = state
        MXNet::NDArray.ftml_update(weight, grad, prev_d, prev_v, prev_z, out=weight,
                    lr=lr, wd=wd, **kwargs)
      end
    end

    registry_manager.register FTML



    # The DCASGD optimizer.
  
    # This class implements the optimizer described in *Asynchronous Stochastic Gradient Descent
    # with Delay Compensation for Distributed Deep Learning*,
    # available at https://arxiv.org/abs/1609.08326.

    # This optimizer accepts the following parameters in addition to those accepted
    # by :class:`.Optimizer`.

    # Parameters
    # ----------
    # +momentum+:: float, optional
    #    The momentum value.

    # +lamda+:: float, optional
    #    Scale DC value.
    # 

    class DCASGD < Base
      def initialize momentum: 0.0, lamda: 0.04, **kwargs
          super **kwargs
          @momentum = momentum
          @weight_previous = {}
          @lamda = lamda
      end
      def create_state index, weight
          if @momentum == 0.0
            return [nil,
                    weight.copy_to(weight.context) ]  # previous weight
          else
            return [MXNet::NDArray.zeros(weight.shape, weight.context, dtype: weight.dtype), # momentum
                    weight.copy_to(weight.context) ]  # previous weight
          end
      end

      def update index, weight, grad, state
          raise unless weight.is_a? MXNet::NDArray
          raise unless grad.is_a? MXNet::NDArray

          update_count(index)
          lr = get_lr(index)
          wd = get_wd(index)
  
          grad = grad * @rescale_grad
          grad = clip(grad, -@clip_gradient, @clip_gradient) unless @clip_gradient.nil?
  
          mom, previous_weight = state
          if mom
              mom *= @momentum
              mom += -lr * (grad + wd * weight + @lamda \
                               * grad * grad * (weight - previous_weight))
          else
              raise 'Momentum must be zero without mom' unless @momentum == 0.0
              mom = -lr * (grad + wd * weight + @lamda \
                           * grad * grad * (weight - previous_weight))
          end

          previous_weight = weight
          weight += mom
      end
    end

    registry_manager.register DCASGD

    

    # TODO: NAG

    class SGLD < Base
        # Stochastic Gradient Riemannian Langevin Dynamics.
    
        # This class implements the optimizer described in the paper *Stochastic Gradient
        # Riemannian Langevin Dynamics on the Probability Simplex*, available at
        # https://papers.nips.cc/paper/4883-stochastic-gradient-riemannian-langevin-dynamics-on-the-probability-simplex.pdf.
    
        # 
        def initialize **kwargs
            super(**kwargs)
        end
    
        def create_state index, weight
            return nil
        end
    
        def update index, weight, grad, state
            raise unless weight.is_a? MXNet::NDArray
            raise unless grad.is_a? MXNet::NDArray

            update_count(index)
            lr = get_lr(index)
            wd = get_wd(index)
    
            grad = grad * @rescale_grad
            grad = clip(grad, -@clip_gradient, @clip_gradient) unless @clip_gradient.nil?

            weight += - lr/2 * (grad + wd * weight)
            weight += MXNet::NDArray::Random.normal(0, Math.sqrt(lr), shape: weight.shape,
                                dtype: weight.dtype, ctx: weight.context)
        end
    end 
    
    registry_manager.register SGLD

    # The Adam optimizer.

    # This class implements the optimizer described in *Adam: A Method for
    # Stochastic Optimization*, available at http://arxiv.org/abs/1412.6980.

    # If the storage types of grad is ``row_sparse``, and ``lazy_update`` is True, \
    # **lazy updates** at step t are applied by::

    #     for row in grad.indices:
    #         rescaled_grad[row] = clip(grad[row] * rescale_grad + wd * weight[row], clip_gradient)
    #         m[row] = beta1 * m[row] + (1 - beta1) * rescaled_grad[row]
    #         v[row] = beta2 * v[row] + (1 - beta2) * (rescaled_grad[row]**2)
    #         lr = learning_rate * sqrt(1 - beta1**t) / (1 - beta2**t)
    #         w[row] = w[row] - lr * m[row] / (sqrt(v[row]) + epsilon)

    # The lazy update only updates the mean and var for the weights whose row_sparse
    # gradient indices appear in the current batch, rather than updating it for all indices.
    # Compared with the original update, it can provide large improvements in model training
    # throughput for some applications. However, it provides slightly different semantics than
    # the original update, and may lead to different empirical results.

    # Otherwise, **standard updates** at step t are applied by::

    #     rescaled_grad = clip(grad * rescale_grad + wd * weight, clip_gradient)
    #     m = beta1 * m + (1 - beta1) * rescaled_grad
    #     v = beta2 * v + (1 - beta2) * (rescaled_grad**2)
    #     lr = learning_rate * sqrt(1 - beta1**t) / (1 - beta2**t)
    #     w = w - lr * m / (sqrt(v) + epsilon)
    class Adam < Base
  
      # This optimizer accepts the following parameters in addition to those accepted
      # by :class:`.Optimizer`.
  
      # For details of the update algorithm, see :class:`~mxnet.ndarray.adam_update`.
  
      # Parameters
      # ----------
      # +beta1+:: float, optional
      #           Exponential decay rate for the first moment estimates.
      # +beta2+:: float, optional
      #           Exponential decay rate for the second moment estimates.
      # +epsilon+:: float, optional
      #           Small value to avoid division by 0.
      # +lazy_update+:: bool, optional
      #           Default is True. If True, lazy updates are applied \
      #           if the storage types of weight and grad are both ``row_sparse``.
      
      def initialize( beta1: 0.9, beta2: 0.99, epsilon: 1e-8, lazy_update: true,
                      weight: nil, batch_axis: 0, **kwargs)
        super(**kwargs)
        @beta1 = beta1
        @beta2 = beta2
        @epsilon = epsilon
        @lazy_update = lazy_update

      end
      
      def create_state(index, weight)
        #TODO: stype =  @lazy_update ? weight.stype : :default
        [MXNet::NDArray.zeros(weight.shape, weight.context, dtype: weight.dtype),  # mean, TODO: stype: stype
                      MXNet::NDArray.zeros(weight.shape, weight.context, dtype: weight.dtype)]  # variance, TODO: stype: stype
      end
      
      def update(index, weight, grad, state)
        raise unless weight.is_a? NDArray
        raise unless grad.is_a? NDArray
        update_count(index)

        lr = get_lr(index)
        wd = get_wd(index)

        t = @index_update_count[index]
        coef1 = 1. - @beta1**t
        coef2 = 1. - @beta2**t
        lr = lr * Math.sqrt(coef2)/coef1

        kwargs = {beta1: @beta1, beta2: @beta2, epsilon: @epsilon,
                  rescale_grad: @rescale_grad}

        kwargs[:clip_gradient] = @clip_gradient if @clip_gradient 
            
        mean, var = state
        MXNet::NDArray.adam_update(weight, grad, mean, var, out: weight,
                    lazy_update: @lazy_update, lr: lr, wd: wd, **kwargs)
      end
    end


    registry_manager.register Adam

    # TODO: AdamGrad

    # TODO: RMSProp

    # TODO: AdaDelta

    # TODO: Ftrl

    # TODO: Adamax

    # TODO: Nadam

    class Test < Base
      def initialize(**kwargs)
        super
      end

      def create_state(index, weight)
        MXNet::NDArray.zeros(weight,shape, weight.context)
      end

      def update(index, weight, grad, state)
        weight[0..-1] += grad * @rescale_grad
        state[0..-1] = weight
        nil
      end
    end

    # Updater for kvstore.
    class Updater
      def initialize(optimizer)
        @optimizer = optimizer
        @states = {}
        @states_synced = {}
      end

      # Updates weight given gradient and index.
      def call(index, grad, weight)
        if !@states.has_key? index
          @states[index] = @optimizer.create_state_multi_precision(index, weight)
          @states_synced[index] = true
        elsif !@states_synced[index]
          @states[index] = sync_state_context(@states[index], weight.context)
          @states_synced[index] = true
        end
        @optimizer.update_multi_precision(index, weight, grad, @states[index])
      end

      def sync_state_context(state, context)
        case state
        when MXNet::NDArray
          state.as_in_context(context)
        when Array
          state.map {|i| sync_state_context(i, context) }
        else
          state
        end
      end

      def states(dump_optimizer: false)
        if dump_optimizer
          Marshal.dump([@states, @optimizer])
        else
          Marshal.dump(@states)
        end
      end

      def states=(states)
        states = Marshal.load(states)
        if states.is_a?(Array) && states.length == 2
          @states, @optimizer = *states
        else
          @states = states
        end
        @states_synced = @states.keys.map {|k| [k, false] }.to_h
        nil
      end
    end
  end
end
